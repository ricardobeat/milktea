module taro;
import milktea;

// msg_to_js converts a milktea::Msg to a JS object.
// Returns a JS object with a "kind" property and message-specific data.
fn void* msg_to_js(Runtime* rt, milktea::Msg msg) {
	void* obj = rt.new_object();

	switch (msg.kind) {
		case milktea::MsgKind.KEY:
			rt.set_prop_str(obj, "kind", "key");

			String key_code = keycode_to_string(msg.key.code, msg.key.rune);

			// Flat fields: msg.code, msg.ctrl, msg.alt, msg.shift
			rt.set_prop_str(obj, "code", key_code);
			rt.set_prop_bool(obj, "ctrl", msg.key.ctrl);
			rt.set_prop_bool(obj, "alt", msg.key.alt);
			rt.set_prop_bool(obj, "shift", msg.key.shift);

			// Also keep msg.key.{code,ctrl,alt,shift} for compatibility
			void* key_obj = rt.new_object();
			rt.set_prop_str(key_obj, "code", key_code);
			rt.set_prop_bool(key_obj, "ctrl", msg.key.ctrl);
			rt.set_prop_bool(key_obj, "alt", msg.key.alt);
			rt.set_prop_bool(key_obj, "shift", msg.key.shift);
			rt.set_prop_obj(obj, "key", key_obj);
			rt.free_value(key_obj);

		case milktea::MsgKind.WINDOW_SIZE:
			rt.set_prop_str(obj, "kind", "window_size");
			rt.set_prop_int(obj, "width", msg.window_size.width);
			rt.set_prop_int(obj, "height", msg.window_size.height);

		case milktea::MsgKind.MOUSE:
			rt.set_prop_str(obj, "kind", "mouse");

			void* mouse_obj = rt.new_object();

			String button_str = mouse_button_to_string(msg.mouse.button);
			rt.set_prop_str(mouse_obj, "button", button_str);

			String action_str = mouse_action_to_string(msg.mouse.action);
			rt.set_prop_str(mouse_obj, "action", action_str);

			rt.set_prop_int(mouse_obj, "row", msg.mouse.row);
			rt.set_prop_int(mouse_obj, "col", msg.mouse.col);
			rt.set_prop_bool(mouse_obj, "shift", msg.mouse.shift);
			rt.set_prop_bool(mouse_obj, "alt", msg.mouse.alt);
			rt.set_prop_bool(mouse_obj, "ctrl", msg.mouse.ctrl);

			rt.set_prop_obj(obj, "mouse", mouse_obj);
			rt.free_value(mouse_obj);

		case milktea::MsgKind.TICK:
			rt.set_prop_str(obj, "kind", "tick");
			rt.set_prop_int(obj, "tag", msg.tag);

		case milktea::MsgKind.QUIT:
			rt.set_prop_str(obj, "kind", "quit");

		case milktea::MsgKind.FOCUS:
			rt.set_prop_str(obj, "kind", "focus");

		case milktea::MsgKind.BLUR:
			rt.set_prop_str(obj, "kind", "blur");

		default:
			rt.set_prop_str(obj, "kind", "none");
	}

	return obj;
}

// js_value_to_cmd converts a JS return value from update() to a milktea::Cmd.
// - null/undefined returns a null Cmd
// - "quit" string returns a quit Cmd
// - Functions and other values are freed and return null (deferred feature)
fn milktea::Cmd js_value_to_cmd(Runtime* rt, void* val) {
	// Check for null/undefined
	if (rt.is_null(val)) {
		rt.free_value(val);
		return null;
	}

	// Check if it's the string "quit"
	ZString cstr = taro_to_cstring(rt.ctx, val);
	rt.free_value(val);
	if (cstr) {
		bool is_quit = cstr.str_view() == "quit";
		taro_free_cstring(rt.ctx, cstr);
		if (is_quit) return &quit_fn;
	}
	return null;
}

// ============================================================
// Helper functions
// ============================================================

fn String keycode_to_string(milktea::KeyCode code, char rune) {
	switch (code) {
		case milktea::KeyCode.RUNE:
			return string::tformat("%c", rune);

		case milktea::KeyCode.ENTER:
			return "enter";
		case milktea::KeyCode.BACKSPACE:
			return "backspace";
		case milktea::KeyCode.ESC:
			return "esc";
		case milktea::KeyCode.TAB:
			return "tab";
		case milktea::KeyCode.UP:
			return "up";
		case milktea::KeyCode.DOWN:
			return "down";
		case milktea::KeyCode.LEFT:
			return "left";
		case milktea::KeyCode.RIGHT:
			return "right";
		case milktea::KeyCode.HOME:
			return "home";
		case milktea::KeyCode.END:
			return "end";
		case milktea::KeyCode.DELETE:
			return "delete";
		case milktea::KeyCode.PAGE_UP:
			return "page_up";
		case milktea::KeyCode.PAGE_DOWN:
			return "page_down";
		case milktea::KeyCode.INSERT:
			return "insert";
		case milktea::KeyCode.F1:
			return "f1";
		case milktea::KeyCode.F2:
			return "f2";
		case milktea::KeyCode.F3:
			return "f3";
		case milktea::KeyCode.F4:
			return "f4";
		case milktea::KeyCode.F5:
			return "f5";
		case milktea::KeyCode.F6:
			return "f6";
		case milktea::KeyCode.F7:
			return "f7";
		case milktea::KeyCode.F8:
			return "f8";
		case milktea::KeyCode.F9:
			return "f9";
		case milktea::KeyCode.F10:
			return "f10";
		case milktea::KeyCode.F11:
			return "f11";
		case milktea::KeyCode.F12:
			return "f12";
		case milktea::KeyCode.CTRL_C:
			return "c";
		default:
			return "none";
	}
}

fn String mouse_button_to_string(milktea::MouseButton button) {
	switch (button) {
		case milktea::MouseButton.MOUSE_LEFT:
			return "left";
		case milktea::MouseButton.MOUSE_MIDDLE:
			return "middle";
		case milktea::MouseButton.MOUSE_RIGHT:
			return "right";
		default:
			return "none";
	}
}

fn String mouse_action_to_string(milktea::MouseAction action) {
	switch (action) {
		case milktea::MouseAction.MOUSE_PRESS:
			return "press";
		case milktea::MouseAction.MOUSE_RELEASE:
			return "release";
		case milktea::MouseAction.MOUSE_MOTION:
			return "motion";
		default:
			return "none";
	}
}

// quit_fn returns a QUIT message
fn milktea::Msg quit_fn() {
	return { .kind = milktea::MsgKind.QUIT };
}