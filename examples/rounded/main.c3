module rounded;

import milktea;

// Entry point lives apart from the model so the test target can compile
// the example's module without colliding with other examples' main().
fn int main() {
	Model m = { };
	// tgp only sends images on the alternate screen, where switching screens
	// cannot drop them; without it the corners never arrive.
	return milktea::@run(&m, { .alt_screen = true });
}
