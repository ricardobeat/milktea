module mouse;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;
import std::core::mem;

struct Model {
	sz mouse_row;
	sz mouse_col;
	milktea::MouseButton last_button;
	milktea::MouseAction last_action;
	bool dragging;
	String[32] trail;
	sz trail_count;
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.mouse_row = 0;
	self.mouse_col = 0;
	self.last_button = MOUSE_NONE;
	self.last_action = MOUSE_PRESS;
	self.dragging = false;
	self.trail_count = 0;
	return null;
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == MOUSE) {
		self.mouse_row = msg.mouse.row;
		self.mouse_col = msg.mouse.col;
		self.last_button = msg.mouse.button;
		self.last_action = msg.mouse.action;
		if (msg.mouse.action == MOUSE_PRESS && msg.mouse.button == MOUSE_LEFT) {
			self.dragging = true;
			if (self.trail_count < self.trail.len) {
				self.trail[self.trail_count] = string::format(mem, "(%d,%d)", msg.mouse.col, msg.mouse.row);
				self.trail_count++;
			}
		}
		if (msg.mouse.action == MOUSE_RELEASE) {
			self.dragging = false;
		}
		if (msg.mouse.action == MOUSE_MOTION && self.dragging) {
			if (self.trail_count < self.trail.len) {
				self.trail[self.trail_count] = string::format(mem, "(%d,%d)", msg.mouse.col, msg.mouse.row);
				self.trail_count++;
			}
		}
		return null;
	}

	if (msg.kind != KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case CTRL_C:
			return milktea::quit();
		case RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'c') {
				foreach (point : self.trail[:self.trail_count]) mem::free(point.ptr);
			self.trail_count = 0;
			}
		default:
	}
	return null;
}

fn void Model.on_destroy(Model* self) @dynamic {
	foreach (point : self.trail[:self.trail_count]) mem::free(point.ptr);
}

fn milktea::Node* Model.view(Model* self) @dynamic {
	glaze::Style title_style = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);

	glaze::Style info_style = glaze::style().foreground(glaze::color_hex("#ff00ff"));

	glaze::Style hint_style = glaze::style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title_style.render("Mouse Event Viewer"));
	out.append_string("\n\n");

	String button_name = "none";
	switch (self.last_button) {
		case MOUSE_LEFT: { button_name = "left"; }
		case MOUSE_MIDDLE: { button_name = "middle"; }
		case MOUSE_RIGHT: { button_name = "right"; }
		default: { }
	}

	String action_name = "press";
	switch (self.last_action) {
		case MOUSE_PRESS: { action_name = "press"; }
		case MOUSE_RELEASE: { action_name = "release"; }
		case MOUSE_MOTION: { action_name = "motion"; }
		default: { }
	}

	out.append_string(info_style.render(string::tformat("Position: (%d, %d)", self.mouse_col, self.mouse_row)));
	out.append_char('\n');
	out.append_string(info_style.render(string::tformat("Button: %s  Action: %s", button_name, action_name)));
	out.append_char('\n');
	out.append_string(info_style.render(string::tformat("Dragging: %s", self.dragging ? "yes" : "no")));
	out.append_char('\n');

	if (self.trail_count > 0) {
		out.append_char('\n');
		out.append_string(title_style.render("Click Trail:"));
		out.append_char('\n');
		for (sz i = 0; i < self.trail_count; i++) {
			out.append_string(self.trail[i]);
			if (i < self.trail_count - 1) {
				out.append_string(" -> ");
			}
		}
	}

	out.append_string("\n\n");
	out.append_string(hint_style.render("Click/drag to track  |  c to clear  |  q to quit"));
	return milktea::text(out.str_view());
}

fn int main() {
	Model m = { };
	if (catch err = milktea::@run_program(&m, { .alt_screen = true, .mouse_mode = MOUSE_MODE_CELL_MOTION })) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}