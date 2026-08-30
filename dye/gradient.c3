module dye;

// BlendSpace selects the color space used to interpolate between the
// endpoints of a gradient.
enum BlendSpace : char {
	LUV, // perceptually even ramp (default)
	HSL, // interpolates hue, saturation, lightness
	HCL, // hue-chroma-lightness, shortest hue path
}

// blend_gradient interpolates from `from` to `to` at t in [0,1] in the
// chosen space. Both endpoints must be TRUECOLOR; there is no fallback
// for other color kinds.
fn Color blend_gradient(Color from, Color to, BlendSpace space, double t) {
	switch (space) {
		case HSL: return blend_hsl(from, to, t);
		case HCL: return blend_hcl(from, to, t);
		default:  return blend_luv(from, to, t);
	}
}
