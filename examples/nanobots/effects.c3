// Exit lifecycle for the nanobots example.
//
// Each exit animation now lives in its own fx_*.c3 file and is reached here
// purely by dispatch: choose an Exit, set the matching effect on the model,
// and let it take over. run_exit picks the Effect struct for the requested
// exit and activates it; start_exit picks which exit runs, avoiding the one
// that ran last cycle.
module nanobots;

fn void Model.start_exit(Model* self) {
	// Draw from the exits *other* than the last one used, so the same
	// effect never runs twice in a row.
	Exit e;
	if (self.exit_forced) {
		// A TAB pick runs once and then clears, so the next cycle goes back
		// to the random rotation on its own.
		e = self.forced_exit;
		self.exit_forced = false;
		self.last_exit = e;
		self.has_last_exit = true;
		self.run_exit(e);
		return;
	}
	self.exit_previewed = false; // a random draw, so the badge dims again
	if (self.has_last_exit) {
		int pick = rand() % (EXIT_COUNT - 1);
		// Shift past the excluded value: indices at or above it move up one,
		// which maps the 3 remaining slots onto the 4 exits with no repeat.
		if (pick >= (int)self.last_exit) pick++;
		e = (Exit)pick;
	} else {
		e = (Exit)(rand() % EXIT_COUNT);
	}
	self.last_exit = e;
	self.has_last_exit = true;
	self.run_exit(e);
}

// Attach the effect that implements `e` and hand it control. Each call swaps
// in a fresh Effect whose setup seeds the shared particles and its own private
// state; from here on Model.step drives fx.step and Model.view calls fx.render.
fn void Model.run_exit(Model* self, Exit e) {
	// Release the previous effect's state before swapping in the new one — a
	// TAB mid-animation switches effects, so the old one has to let go.
	if (self.fx_active && self.fx.teardown) self.fx.teardown(self);
	switch (e) {
		case Exit.EXPLODE: self.fx = explode_effect();
		case Exit.COLLAPSE: self.fx = collapse_effect();
		case Exit.SLICE: self.fx = slice_effect();
		case Exit.VORTEX: self.fx = vortex_effect();
		case Exit.DISSOLVE: self.fx = dissolve_effect();
		case Exit.SHEAR: self.fx = shear_effect();
		case Exit.TOPPLE: self.fx = topple_effect();
		case Exit.IMPLODE: self.fx = implode_effect();
		case Exit.SPLAT: self.fx = splat_effect();
		case Exit.FIRE: self.fx = fire_effect();
		case Exit.SPHERES: self.fx = spheres_effect();
		case Exit.RAINBOW: self.fx = rainbow_effect();
		case Exit.GRADIENT: self.fx = gradient_effect();
	}
	self.fx_active = true;
	self.fx.setup(self);
}