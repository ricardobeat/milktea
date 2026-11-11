module glaze;

import dye;

// Color and its constructors live in dye, the color module glaze and xray
// share. They are aliased here so a glaze user never has to name dye, and so
// every existing `glaze::color_hex(...)` call site keeps working.
// 
// dye::Color is the wider type: it carries an alpha channel and a TRANSPARENT
// kind that only xray's compositor acts on. glaze renders to a string and has
// no layer to blend against, so it ignores both — see dye's write_sgr_params.
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
