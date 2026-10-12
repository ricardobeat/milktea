module nineslice;

import milktea;

// Entry point lives apart from the model so the test target can compile
// the example's module without colliding with other examples' main().
fn int main() {
	Model m = { };
	return milktea::@run(&m, { .alt_screen = true, .mouse_mode = milktea::MouseMode.MOUSE_MODE_CELL_MOTION });
}
