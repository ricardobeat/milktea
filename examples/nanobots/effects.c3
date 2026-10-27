// Exit lifecycle for the nanobots example.
//
// Each exit animation now lives in its own fx_*.c3 file and is reached here
// purely by dispatch: choose an Exit, set the matching effect on the model,
// and let it take over. run_exit picks the Effect struct for the requested
// exit and activates it; start_exit picks which exit runs, avoiding the one
// that ran last cycle.
module nanobots;

fn void Model.start_exit(Model* self) {
	// Deal from a shuffled deck, so every effect plays once before any
	// repeats, and never twice in a row.
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
	e = self.deal_exit();
	self.last_exit = e;
	self.has_last_exit = true;
	self.run_exit(e);
}

// Deal the next exit from the shuffled bag, refilling it with a Fisher-Yates
// shuffle once it runs out. A fresh deck whose first card matches the exit
// that just ran swaps it to the back, so a reshuffle never repeats.
fn Exit Model.deal_exit(Model* self) {
	if (self.exit_bag_left == 0) {
		for (sz i = 0; i < EXIT_COUNT; i++) self.exit_bag[i] = (Exit)i;
		for (sz i = EXIT_COUNT - 1; i > 0; i--) {
			sz j = rand() % (i + 1);
			Exit t = self.exit_bag[i];
			self.exit_bag[i] = self.exit_bag[j];
			self.exit_bag[j] = t;
		}
		// Cards are dealt from the end, so the first one out is the last slot.
		if (self.has_last_exit && self.exit_bag[EXIT_COUNT - 1] == self.last_exit) {
			self.exit_bag[EXIT_COUNT - 1] = self.exit_bag[0];
			self.exit_bag[0] = self.last_exit;
		}
		self.exit_bag_left = EXIT_COUNT;
	}
	return self.exit_bag[--self.exit_bag_left];
}

// Attach the effect that implements `e` and hand it control. Each call swaps
// in a fresh Effect whose setup seeds the shared particles and its own private
// state; from here on Model.step drives fx.step and Model.view calls fx.render.
fn void Model.run_exit(Model* self, Exit e) {
	// Release the previous effect's state before swapping in the new one — a
	// TAB mid-animation switches effects, so the old one has to let go.
	if (self.fx_active && self.fx.teardown) self.fx.teardown(self);
	switch (e) {
		case EXPLODE: self.fx = explode_effect();
		case COLLAPSE: self.fx = collapse_effect();
		case SLICE: self.fx = slice_effect();
		case VORTEX: self.fx = vortex_effect();
		case DISSOLVE: self.fx = dissolve_effect();
		case SHEAR: self.fx = shear_effect();
		case TOPPLE: self.fx = topple_effect();
		case IMPLODE: self.fx = implode_effect();
		case SPLAT: self.fx = splat_effect();
		case FIRE: self.fx = fire_effect();
		case SPHERES: self.fx = spheres_effect();
		case RAINBOW: self.fx = rainbow_effect();
		case GRADIENT: self.fx = gradient_effect();
	}
	self.fx_active = true;
	self.fx.setup(self);
}