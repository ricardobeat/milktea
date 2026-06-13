module glaze;

import std::math;
import std::core::string;
import std::core::dstring;

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
// Hue takes the shortest path around the wheel.
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

	return hsl(h, s1 + t * (s2 - s1), l1 + t * (l2 - l1));
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
// Hue takes the shortest path around the wheel.
fn Color blend_hcl(Color a, Color b, double t) @export {
	// a → LUV → HCL
	double ar = _linearize((double)a.r / 255.0);
	double ag = _linearize((double)a.g / 255.0);
	double ab = _linearize((double)a.b / 255.0);
	double ax, ay, az;
	_rgb_to_xyz(ar, ag, ab, &ax, &ay, &az);
	double al, au, av;
	_xyz_to_luv(ax, ay, az, &al, &au, &av);
	double ah, ac, acl;
	_luv_to_hcl(al, au, av, &ah, &ac, &acl);

	// b → LUV → HCL
	double br = _linearize((double)b.r / 255.0);
	double bg = _linearize((double)b.g / 255.0);
	double bb = _linearize((double)b.b / 255.0);
	double bx, by, bz;
	_rgb_to_xyz(br, bg, bb, &bx, &by, &bz);
	double bl, bu, bv;
	_xyz_to_luv(bx, by, bz, &bl, &bu, &bv);
	double bh, bc, bcl;
	_luv_to_hcl(bl, bu, bv, &bh, &bc, &bcl);

	// Shortest-path hue
	double dh = bh - ah;
	if (dh > 180.0)  dh -= 360.0;
	if (dh < -180.0) dh += 360.0;
	double h = ah + t * dh;
	if (h < 0.0) h += 360.0;
	if (h >= 360.0) h -= 360.0;

	return hcl(h, ac + t * (bc - ac), acl + t * (bcl - acl));
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

fn sz _utf8_char_len(char b) @local {
	if ((b & 0x80) == 0)    return 1;
	if ((b & 0xe0) == 0xc0) return 2;
	if ((b & 0xf0) == 0xe0) return 3;
	if ((b & 0xf8) == 0xf0) return 4;
	return 1;
}

fn String gradient_text(String text, Color from, Color to, bool bold = true) {
	int width = string_width(text);
	if (width <= 0) return text;

	DString out = dstring::temp();
	sz i = 0;
	int col = 0;
	while (i < text.len) {
		sz clen = _utf8_char_len(text[i]);
		if (clen > text.len - i) clen = text.len - i;
		String ch = text[i..i + clen - 1];
		int ch_w = string_width(ch);

		double t = width > 1 ? (double)col / (double)(width - 1) : 0.0;
		Color c = blend_luv(from, to, t);
		Style s = style().foreground(c);
		if (bold) s = s.bold(true);
		out.append_string(s.render(ch));

		col += ch_w > 0 ? ch_w : 1;
		i += clen;
	}
	return out.str_view();
}