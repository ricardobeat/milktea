module glaze;

import dye;
import std::core::dstring;

// Color and its constructors live in dye, the color module glaze and xray
// share. They are aliased here so a glaze user never has to name dye, and so
// every existing `glaze::color_hex(...)` call site keeps working.
// 
// dye::Color is the wider type: it carries an alpha channel and a TRANSPARENT
// kind that only xray's compositor acts on. glaze renders to a string and has
// no layer to blend against, so it ignores both — see write_sgr_params.
alias Color = dye::Color;
alias ColorKind = dye::ColorKind;

alias color_none = dye::color_none;
alias color_ansi = dye::color_ansi;
alias color_256 = dye::color_256;
alias color_hex = dye::color_hex;

alias hsl = dye::hsl;
alias hcl = dye::hcl;
alias blend_hsl = dye::blend_hsl;
alias blend_hcl = dye::blend_hcl;
alias blend_luv = dye::blend_luv;
alias color_ramp = dye::color_ramp;

// write_sgr_params appends this color's SGR parameters to out, without the
// surrounding CSI or final `m` — the caller is assembling a longer sequence.
// 
// NONE writes nothing (the terminal keeps its default), and so does
// TRANSPARENT: it means "inherit from the layer below", which is a compositing
// idea with no SGR spelling.
fn void Color.write_sgr_params(self, DString* out, bool foreground) {
	switch (self.kind) {
		case NONE:
		case TRANSPARENT:
		case ANSI:
			if (self.index < 8) {
				out.appendf(foreground ? "3%d" : "4%d", self.index);
			} else {
				out.appendf(foreground ? "9%d" : "10%d", self.index - 8);
			}
		case ANSI256:
			out.appendf(foreground ? "38;5;%d" : "48;5;%d", (int)self.index);
		case TRUECOLOR:
			out.appendf(foreground ? "38;2;%d;%d;%d" : "48;2;%d;%d;%d", self.r, self.g, self.b);
	}
}