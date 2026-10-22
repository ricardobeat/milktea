module dye;

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

// ── HSL ────────────────────────────────────────────────────────────────────

fn double _hue_to_rgb(double p, double q, double t) @local {
	if (t < 0.0) t += 1.0;
	if (t > 1.0) t -= 1.0;
	if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
	if (t < 0.5) return q;
	if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
	return p;
}

// hsl constructs a TRUECOLOR Color from HSL values.
// h: 0.0→1.0 wraps the full colour wheel (0=red, 0.33=green, 0.66=blue).
// s: 0.0 (grey) → 1.0 (full saturation).
// l: 0.0 (black) → 0.5 (vivid) → 1.0 (white).
fn Color hsl(double h, double s, double l) @export {
	double r, g, b;
	if (s < 1e-10) {
		r = l; g = l; b = l;
	} else {
		double q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
		double p = 2.0 * l - q;
		r = _hue_to_rgb(p, q, h + 1.0 / 3.0);
		g = _hue_to_rgb(p, q, h);
		b = _hue_to_rgb(p, q, h - 1.0 / 3.0);
	}
	return {
		.kind = ColorKind.TRUECOLOR,
		.r = (char)(int)(r * 255.0 + 0.5),
		.g = (char)(int)(g * 255.0 + 0.5),
		.b = (char)(int)(b * 255.0 + 0.5),
	};
}

fn void _rgb_to_hsl(char ri, char gi, char bi, double* h, double* s, double* l) @local {
	double r = (double)ri / 255.0;
	double g = (double)gi / 255.0;
	double b = (double)bi / 255.0;
	double max = r;
	if (g > max) max = g;
	if (b > max) max = b;
	double min = r;
	if (g < min) min = g;
	if (b < min) min = b;
	*l = (max + min) * 0.5;
	if (max - min < 1e-10) {
		*h = 0.0;
		*s = 0.0;
		return;
	}
	double d = max - min;
	*s = *l > 0.5 ? d / (2.0 - max - min) : d / (max + min);
	if (max == r) {
		*h = (g - b) / d + (g < b ? 6.0 : 0.0);
	} else if (max == g) {
		*h = (b - r) / d + 2.0;
	} else {
		*h = (r - g) / d + 4.0;
	}
	*h /= 6.0;
}

// blend_hsl interpolates between two TRUECOLOR Colors in HSL space.
// Hue takes the shortest path around the wheel, opacity is averaged with t.
fn Color blend_hsl(Color a, Color b, double t) @export {
	double h1, s1, l1;
	double h2, s2, l2;
	_rgb_to_hsl(a.r, a.g, a.b, &h1, &s1, &l1);
	_rgb_to_hsl(b.r, b.g, b.b, &h2, &s2, &l2);

	// Shortest-path hue interpolation
	double dh = h2 - h1;
	if (dh > 0.5)  dh -= 1.0;
	if (dh < -0.5) dh += 1.0;
	double h = h1 + t * dh;
	if (h < 0.0) h += 1.0;
	if (h >= 1.0) h -= 1.0;

	Color c = hsl(h, s1 + t * (s2 - s1), l1 + t * (l2 - l1));
	c.a = blend_alpha(a, b, t);
	return c;
}

// ── HCL (cylindrical LUV) ──────────────────────────────────────────────────

fn void _luv_to_hcl(double l, double u, double v, double* h, double* c, double* hcl_l) @local {
	*c = math::sqrt(u * u + v * v);
	*hcl_l = l;
	if (*c < 1e-10) {
		*h = 0.0;
		return;
	}
	*h = math::atan2(v, u) * 180.0 / math::PI;
	if (*h < 0.0) *h += 360.0;
}

fn void _hcl_to_luv(double h, double c, double l, double* u, double* v) @local {
	double rad = h * math::PI / 180.0;
	*u = c * math::cos(rad);
	*v = c * math::sin(rad);
}

// hcl constructs a TRUECOLOR Color from HCL values.
// h: hue in degrees (0=red, 120=green, 240=blue, wraps at 360).
// c: chroma (0=grey, ~100-150 for vivid colours at mid lightness).
// l: perceptual lightness (0=black, 100=white).
fn Color hcl(double h, double c, double l) @export {
	double u, v;
	_hcl_to_luv(h, c, l, &u, &v);

	double x, y, z;
	_luv_to_xyz(l, u, v, &x, &y, &z);
	double r, g, b;
	_xyz_to_rgb(x, y, z, &r, &g, &b);

	if (r < 0.0) r = 0.0; if (r > 1.0) r = 1.0;
	if (g < 0.0) g = 0.0; if (g > 1.0) g = 1.0;
	if (b < 0.0) b = 0.0; if (b > 1.0) b = 1.0;

	return {
		.kind = ColorKind.TRUECOLOR,
		.r = (char)(int)(_delinearize(r) * 255.0 + 0.5),
		.g = (char)(int)(_delinearize(g) * 255.0 + 0.5),
		.b = (char)(int)(_delinearize(b) * 255.0 + 0.5),
	};
}

// blend_hcl interpolates between two TRUECOLOR Colors in HCL space.
// Hue takes the shortest path around the wheel, opacity is averaged with t.
fn Color blend_hcl(Color a, Color b, double t) @export {
	Luv la = luv_of(a);
	double ah, ac, acl;
	_luv_to_hcl(la.l, la.u, la.v, &ah, &ac, &acl);
	Luv lb = luv_of(b);
	double bh, bc, bcl;
	_luv_to_hcl(lb.l, lb.u, lb.v, &bh, &bc, &bcl);;

	// Shortest-path hue
	double dh = bh - ah;
	if (dh > 180.0)  dh -= 360.0;
	if (dh < -180.0) dh += 360.0;
	double h = ah + t * dh;
	if (h < 0.0) h += 360.0;
	if (h >= 360.0) h -= 360.0;

	Color c = hcl(h, ac + t * (bc - ac), acl + t * (bcl - acl));
	c.a = blend_alpha(a, b, t);
	return c;
}

// ── Public API ───────────────────────────────────────────────────────────────

// Luv is a colour in the CIE LUV space, the space blend_luv and color_ramp
// work in.
struct Luv {
	double l;
	double u;
	double v;
}

// luv_of converts a TRUECOLOR Color to LUV.
fn Luv luv_of(Color c) @local {
	double r = _linearize((double)c.r / 255.0);
	double g = _linearize((double)c.g / 255.0);
	double b = _linearize((double)c.b / 255.0);
	double x, y, z;
	_rgb_to_xyz(r, g, b, &x, &y, &z);
	double l, u, v;
	_xyz_to_luv(x, y, z, &l, &u, &v);
	return { .l = l, .u = u, .v = v };
}

// color_of converts LUV back to a TRUECOLOR Color, clipped to the sRGB gamut.
fn Color color_of(Luv c) @local {
	double x, y, z;
	_luv_to_xyz(c.l, c.u, c.v, &x, &y, &z);
	double r, g, b;
	_xyz_to_rgb(x, y, z, &r, &g, &b);
	if (r < 0.0) r = 0.0;
	if (r > 1.0) r = 1.0;
	if (g < 0.0) g = 0.0;
	if (g > 1.0) g = 1.0;
	if (b < 0.0) b = 0.0;
	if (b > 1.0) b = 1.0;
	return {
		.kind = ColorKind.TRUECOLOR,
		.r = (char)(int)(_delinearize(r) * 255.0 + 0.5),
		.g = (char)(int)(_delinearize(g) * 255.0 + 0.5),
		.b = (char)(int)(_delinearize(b) * 255.0 + 0.5),
	};
}

// lerp_luv blends two LUV colours, t=0 gives a, t=1 gives b.
fn Luv lerp_luv(Luv a, Luv b, double t) @local {
	double s = 1.0 - t;
	return { .l = s * a.l + t * b.l, .u = s * a.u + t * b.u, .v = s * a.v + t * b.v };
}

// blend_alpha interpolates the opacity of two colours. Color.a holds 0 for
// opaque, so the interpolation runs on the effective values.
fn char blend_alpha(Color a, Color b, double t) @local {
	int ai = (int)a.effective_alpha();
	int bi = (int)b.effective_alpha();
	return (char)(ai + (int)(t * (double)(bi - ai)));
}

// blend_luv interpolates between two TRUECOLOR Colors in LUV space.
// t=0 returns a, t=1 returns b. Works like colorful.BlendLuv in Go.
fn Color blend_luv(Color a, Color b, double t) @export {
	Color c = color_of(lerp_luv(luv_of(a), luv_of(b), t));
	c.a = blend_alpha(a, b, t);
	return c;
}

// color_ramp returns an array of n colors blended from a to b in LUV space.
// Caller provides the output slice (length n).
fn void color_ramp(Color a, Color b, Color[] out) {
	sz n = out.len;
	if (n == 0) return;
	if (n == 1) {
		out[0] = a;
		return;
	}
	// Both endpoints are converted once here rather than once per step.
	Luv la  = luv_of(a);
	Luv lb  = luv_of(b);
	int ai  = (int)a.effective_alpha();
	int dai = (int)b.effective_alpha() - ai;
	for (sz i = 0; i < n; i++) {
		double t = (double)i / (double)(n - 1);
		Color c  = color_of(lerp_luv(la, lb, t));
		c.a = (char)(ai + (int)(t * (double)dai));
		out[i] = c;
	}
}

