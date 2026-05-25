module glaze;

import std::math;

// ── sRGB ↔ linear ────────────────────────────────────────────────────────────

fn double _linearize(double c) @local {
	if (c <= 0.04045) return c / 12.92;
	return math::pow((c + 0.055) / 1.055, 2.4);
}

fn double _delinearize(double c) @local {
	if (c <= 0.0031308) return 12.92 * c;
	return 1.055 * math::pow(c, 1.0 / 2.4) - 0.055;
}

// ── linear RGB → XYZ (D65) ───────────────────────────────────────────────────

fn void _rgb_to_xyz(double r, double g, double b, double* x, double* y, double* z) @local {
	*x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375;
	*y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750;
	*z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041;
}

fn void _xyz_to_rgb(double x, double y, double z, double* r, double* g, double* b) @local {
	*r = x * 3.2404542 + y * -1.5371385 + z * -0.4985314;
	*g = x * -0.9692660 + y * 1.8760108 + z * 0.0415560;
	*b = x * 0.0556434 + y * -0.2040259 + z * 1.0572252;
}

// ── XYZ → LUV ────────────────────────────────────────────────────────────────
// Reference white D65: Xn=0.95047, Yn=1.00000, Zn=1.08883

const double XN @local = 0.95047;
const double YN @local = 1.00000;
const double ZN @local = 1.08883;

fn double _u_prime(double x, double y, double z) @local {
	double denom = x + 15.0 * y + 3.0 * z;
	if (denom < 1e-10) return 0.0;
	return 4.0 * x / denom;
}

fn double _v_prime(double x, double y, double z) @local {
	double denom = x + 15.0 * y + 3.0 * z;
	if (denom < 1e-10) return 0.0;
	return 9.0 * y / denom;
}

fn void _xyz_to_luv(double x, double y, double z, double* out_l, double* out_u, double* out_v) @local {
	double yr = y / YN;
	*out_l = yr > 0.008856 ? 116.0 * math::pow(yr, 1.0 / 3.0) - 16.0 : 903.3 * yr;

	double u0 = _u_prime(XN, YN, ZN);
	double v0 = _v_prime(XN, YN, ZN);
	double up = _u_prime(x, y, z);
	double vp = _v_prime(x, y, z);

	*out_u = 13.0 * (*out_l) * (up - u0);
	*out_v = 13.0 * (*out_l) * (vp - v0);
}

fn void _luv_to_xyz(double lv, double uv, double vv, double* x, double* y, double* z) @local {
	if (lv <= 0.0) {
		*x = 0.0;
		*y = 0.0;
		*z = 0.0;
		return;
	}

	double u0 = _u_prime(XN, YN, ZN);
	double v0 = _v_prime(XN, YN, ZN);

	*y = lv > 8.0 ? YN * math::pow((lv + 16.0) / 116.0, 3.0) : YN * lv / 903.3;

	double up = uv / (13.0 * lv) + u0;
	double vp = vv / (13.0 * lv) + v0;

	*x = (*y) * 9.0 * up / (4.0 * vp);
	*z = (*y) * (12.0 - 3.0 * up - 20.0 * vp) / (4.0 * vp);
}

// ── Public API ───────────────────────────────────────────────────────────────

// blend_luv interpolates between two TRUECOLOR Colors in LUV space.
// t=0 returns a, t=1 returns b. Works like colorful.BlendLuv in Go.
fn Color blend_luv(Color a, Color b, double t) @export {
	// Convert a to LUV
	double ar   = _linearize((double)a.r / 255.0);
	double ag   = _linearize((double)a.g / 255.0);
	double ab_c = _linearize((double)a.b / 255.0);
	double ax, ay, az;
	_rgb_to_xyz(ar, ag, ab_c, &ax, &ay, &az);
	double al, au, av;
	_xyz_to_luv(ax, ay, az, &al, &au, &av);

	// Convert b to LUV
	double br   = _linearize((double)b.r / 255.0);
	double bg   = _linearize((double)b.g / 255.0);
	double bb_c = _linearize((double)b.b / 255.0);
	double bx, by, bz;
	_rgb_to_xyz(br, bg, bb_c, &bx, &by, &bz);
	double bl, bu, bv;
	_xyz_to_luv(bx, by, bz, &bl, &bu, &bv);

	// Lerp in LUV
	double s  = 1.0 - t;
	double ml = s * al + t * bl;
	double mu = s * au + t * bu;
	double mv = s * av + t * bv;

	// Back to sRGB
	double mx, my, mz;
	_luv_to_xyz(ml, mu, mv, &mx, &my, &mz);
	double mr, mg, mb;
	_xyz_to_rgb(mx, my, mz, &mr, &mg, &mb);

	// Clamp and delinearize
	if (mr < 0.0) mr = 0.0;
	if (mr > 1.0) mr = 1.0;
	if (mg < 0.0) mg = 0.0;
	if (mg > 1.0) mg = 1.0;
	if (mb < 0.0) mb = 0.0;
	if (mb > 1.0) mb = 1.0;

	return {
		.kind = ColorKind.TRUECOLOR,
		.r = (char)(int)(_delinearize(mr) * 255.0 + 0.5),
		.g = (char)(int)(_delinearize(mg) * 255.0 + 0.5),
		.b = (char)(int)(_delinearize(mb) * 255.0 + 0.5),
	};
}

// color_ramp returns an array of n colors blended from a to b in LUV space.
// Caller provides the output slice (length n).
fn void color_ramp(Color a, Color b, Color[] out) {
	int n = (int)out.len;
	if (n == 0) return;
	if (n == 1) {
		out[0] = a;
		return;
	}
	for (int i = 0; i < n; i++) {
		out[i] = blend_luv(a, b, (double)i / (double)(n - 1));
	}
}