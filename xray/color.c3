module xray;

import dye;

// Color and its constructors live in dye, the color module xray and glaze
// share. They are aliased here so an xray user never has to name dye, and so
// every existing `xray::color_rgb(...)` call site keeps working.
alias Color = dye::Color;
alias ColorKind = dye::ColorKind;
alias ColorProfile = dye::ColorProfile;

alias color_none = dye::color_none;
alias color_transparent = dye::color_transparent;
alias color_ansi = dye::color_ansi;
alias color_256 = dye::color_256;
alias color_rgb = dye::color_rgb;
alias color_rgba = dye::color_rgba;
alias color_hex = dye::color_hex;

alias palette_256 = dye::palette_256;
alias downsample_truecolor_to_256 = dye::downsample_truecolor_to_256;
alias downsample_256_to_ansi = dye::downsample_256_to_ansi;
alias downsample_truecolor_to_ansi = dye::downsample_truecolor_to_ansi;

alias BlendSpace = dye::BlendSpace;
alias blend_gradient = dye::blend_gradient;