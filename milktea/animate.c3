module milktea;

import xray;

// Animating a node. `animate` reads a Tween against the paint clock and writes
// the result into the node's offset and alpha, then asks for the next frame
// through the node's own repaint request — so an animated view needs no frame
// messages, no timer bookkeeping and no phase tracking in the model:
// 
//     fn milktea::View Model.view(&self) @dynamic {
//         return milktea::draw(milktea::root()
//             .add(milktea::animate(
//                 milktea::text(panel, body).center(),
//                 milktea::slide_down(6).fade(),
//                 &self.anim)));
//     }
// 
// The model's only job is to start the tween:
// 
//     self.anim = milktea::tween_at(milktea::time_ms(), 260);
// 
// This lives in milktea rather than xray because it needs a clock, and xray
// deliberately has none — it takes now_ms from its caller (see
// xray::ScreenBuffer.draw_cursor). Everything it writes is a plain xray field,
// so the node stays an ordinary node.

// Motion describes what an animation does to a node: where it travels from,
// and whether it fades. The offsets are the *starting* displacement, which the
// tween drives to zero as it runs, so the node finishes wherever the layout
// solver put it.
struct Motion {
	int from_dx;
	int from_dy;
	bool fades;
}

// slide_down starts the node `rows` above its solved position and travels down
// onto it. Negative rows slide up instead.
fn Motion slide_down(int rows) => { .from_dy = -rows, .from_dx = 0, .fades = false };

// slide_up starts the node `rows` below its solved position.
fn Motion slide_up(int rows) => { .from_dy = rows, .from_dx = 0, .fades = false };

// slide_in starts the node `cols` to the left of its solved position.
// Negative cols come from the right.
fn Motion slide_in(int cols) => { .from_dx = -cols, .from_dy = 0, .fades = false };

// fade adds a fade-in to a motion, or on its own animates opacity with no
// movement: `fade_in()` is `Motion{}.fade()`.
fn Motion Motion.fade(self) {
	Motion m = self;
	m.fades = true;
	return m;
}

// fade_in animates opacity alone, leaving position to the solver.
fn Motion fade_in() => { .from_dx = 0, .from_dy = 0, .fades = true };

// animate applies `motion` to `node` according to `tw`'s current progress and
// returns the node, so it drops into a builder chain. It is safe to call on a
// null node (draw trees are built with conditional children), and on a
// finished tween — a settled animation writes its end state and stops asking
// for frames.
// 
// The tween is taken by pointer because a clock-driven one updates itself here
// against the paint clock; that is what lets the model own the Tween as plain
// state and never touch it again after starting it.
fn xray::Node* animate(xray::Node* node, Motion motion, Tween* tw) {
	if (node == null || tw == null) return node;

	bool running = tw.advance_to((long)time_ms());

	// The motion's offsets are where the node starts; the tween carries them
	// to zero, so the node settles exactly on its solved position rather than
	// near it. lerp rounds to nearest, which keeps the travel smooth in both
	// directions instead of biasing toward zero.
	if (motion.from_dx != 0 || motion.from_dy != 0) {
		node.offset(tw.lerp(motion.from_dx, 0), tw.lerp(motion.from_dy, 0));
	}

	if (motion.fades) node.alpha(tw.alpha());

	// Ask for the next frame only while there is one to draw. paint() collects
	// the smallest request in the tree and milktea::draw arms a single timer
	// for it, so a settled animation costs nothing.
	if (running) node.repaint_after((int)FRAME_MS);

	return node;
}