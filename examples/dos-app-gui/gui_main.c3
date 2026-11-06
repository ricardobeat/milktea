// GUI entrypoint for dos-app, built only by the examples/dos-app-gui
// target (see project.json) — the normal `examples/dos-app` target uses
// dos.c3's main() instead and never touches the GUI.
module dos_app;

import milktea;
import milktea_gui;

fn int main() {
	DosModel m = { };
	milktea_gui::run((milktea::Model)&m, {
		.title = "dos-app (gui)",
		.cols = 80, .rows = 24,
		.cell_w = 10, .cell_h = 19,
		.font_size = 17,
		// The menu bar stands in for the title bar, with the window buttons in it.
		.chrome_rows = 1,
	});
	return 0;
}
