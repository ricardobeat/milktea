module milktea;

import xray;

// Transitions: moving a node between two states as a Tween runs — a modal
// sliding in and fading up, then back out. `Node.transition` reads the tween
// at now() and writes the result into the node's offset and alpha, so it
// drops into a view's builder chain and changes nothing but the node:
// 
//     dialog = milktea::text(panel, body).center()
//         .transition(milktea::slide_down(6).fade(), self.anim);
// 
// The model's only job is to start the tween, which also keeps frames coming
// until it ends:
// 
//     self.anim = milktea::tween_at(milktea::now(), 260);
// 
// This is the other half of Node.animate. A node that animates changes for as
// long as it is on screen — a spinner, a caret — and says so from the view. A
// transition is a change of state, which update() starts and the tween times.
// 
// This lives in milktea rather than xray because it needs Tween and the frame
// clock, and xray deliberately has neither. Everything it writes is a plain
// xray field, so the node stays an ordinary node.

// Motion describes what an animation does to a node: where it travels from,
// and whether it fades. The offsets are the *starting* displacement, which the
// tween drives to zero as it runs, so the node finishes wherever the layout
// solver put it.
struct Motion {
	sz from_dx;
	sz from_dy;
	bool fades;
}

// slide_down starts the node `rows` above its solved position and travels down
// onto it. Negative rows slide up instead.
fn Motion slide_down(sz rows) => { .from_dy = -rows, .from_dx = 0, .fades = false };

// slide_up starts the node `rows` below its solved position.
fn Motion slide_up(sz rows) => { .from_dy = rows, .from_dx = 0, .fades = false };

// slide_in starts the node `cols` to the left of its solved position.
// Negative cols come from the right.
fn Motion slide_in(sz cols) => { .from_dx = -cols, .from_dy = 0, .fades = false };

// fade adds a fade-in to a motion, or on its own animates opacity with no
// movement: `fade_in()` is `Motion{}.fade()`.
fn Motion Motion.fade(self) {
	Motion m = self;
	m.fades = true;
	return m;
}

// fade_in animates opacity alone, leaving position to the solver.
fn Motion fade_in() => { .from_dx = 0, .from_dy = 0, .fades = true };

// transition applies `motion` to the node according to `tw`'s progress at
// now() and returns the node, so it drops into a builder chain. A finished
// tween writes the motion's end state: the node rests where the layout solver
// put it, fully opaque — or, played in reverse, fully away.
fn xray::Node* xray::Node.transition(&self, Motion motion, Tween tw) {
	if (self == null) return self;

	// The motion's offsets are where the node starts; the tween carries them
	// to zero, so the node settles exactly on its solved position rather than
	// near it. lerp rounds to nearest, which keeps the travel smooth in both
	// directions instead of biasing toward zero.
	if (motion.from_dx != 0 || motion.from_dy != 0) {
		self.offset(tw.lerp(motion.from_dx, 0), tw.lerp(motion.from_dy, 0));
	}

	if (motion.fades) self.alpha(tw.alpha());
	return self;
}
