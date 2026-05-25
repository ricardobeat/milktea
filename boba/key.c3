module boba;

import milktea;

// KeyBinding defines a mapping from key conditions to named actions.
struct KeyBinding {
	String key; // key string to match (e.g. "ctrl+c", "up", "enter", "q")
	String action; // named action (e.g. "quit", "select", "next")
	bool alt; // requires Alt modifier
	bool ctrl; // requires Ctrl modifier
}

// KeyMap holds a set of named key bindings.
struct KeyMap {
	KeyBinding[32] bindings;
	int count;
}

// new_keymap creates an empty key map.
fn KeyMap new_keymap() {
	return { };
}

// bind adds a key binding to the map.
fn void KeyMap.bind(&self, String key, String action) {
	if (self.count >= 32) return;
	self.bindings[self.count] = { .key = key, .action = action };
	self.count++;
}

// bind_mod adds a key binding with modifier requirements.
fn void KeyMap.bind_mod(&self, String key, String action, bool alt, bool ctrl) {
	if (self.count >= 32) return;
	self.bindings[self.count] = { .key = key, .action = action, .alt = alt, .ctrl = ctrl };
	self.count++;
}

// match checks a KeyMsg against all bindings and returns the action name, or "" if none match.
// Uses milktea::KeyMsg.code and milktea::KeyMsg.rune for matching.
fn String KeyMap.match(&self, milktea::KeyMsg k) {
	for (int i = 0; i < self.count; i++) {
		KeyBinding b = self.bindings[i];

		// Check modifiers
		if (b.alt && !k.alt) continue;
		if (b.ctrl && !k.ctrl) continue;

		// Match by key code
		String matched = key_match_string(k);
		if (matched == b.key) return b.action;
	}
	return "";
}

// key_match_string converts a KeyMsg to a string for matching.
fn String key_match_string(milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.CTRL_C: return "ctrl+c";
		case milktea::KeyCode.UP: return "up";
		case milktea::KeyCode.DOWN: return "down";
		case milktea::KeyCode.LEFT: return "left";
		case milktea::KeyCode.RIGHT: return "right";
		case milktea::KeyCode.PAGE_UP: return "pgup";
		case milktea::KeyCode.PAGE_DOWN: return "pgdown";
		case milktea::KeyCode.HOME: return "home";
		case milktea::KeyCode.END: return "end";
		case milktea::KeyCode.ENTER: return "enter";
		case milktea::KeyCode.ESC: return "esc";
		case milktea::KeyCode.TAB: return "tab";
		case milktea::KeyCode.BACKSPACE: return "backspace";
		case milktea::KeyCode.DELETE: return "delete";
		case milktea::KeyCode.RUNE:
			if (k.rune == ' ') return "space";
			return string::tformat("%c", k.rune);
		default: return "";
	}
}

// has_binding returns true if any binding matches the given action.
fn bool KeyMap.has_binding(&self, String action) {
	for (int i = 0; i < self.count; i++) {
		if (self.bindings[i].action == action) return true;
	}
	return false;
}

// default_help_keymap returns a common help key map.
fn KeyMap default_help_keymap() {
	KeyMap km = new_keymap();
	km.bind("q", "quit");
	km.bind("ctrl+c", "quit");
	km.bind("esc", "quit");
	km.bind("up", "up");
	km.bind("down", "down");
	km.bind("enter", "select");
	return km;
}