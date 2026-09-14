// GUI entrypoint for doom-fire, built only by the examples/doom-fire-gui
// target (see project.json) — the normal `examples/doom-fire` target uses
// doom-fire.c3's main() instead and never touches raylib.
module doom_fire;

import milktea;
import milktea_gui;

fn int main() {
	FireModel m = { };
	milktea_gui::run((milktea::Model)&m, {
		.title = "doom-fire (raylib)",
		.cols = 80, .rows = 24,
		.cell_w = 10, .cell_h = 19,
		.font_size = 17,
		.undecorated = true,
		.corner_radius = 16.0,
	});
	return 0;
}
