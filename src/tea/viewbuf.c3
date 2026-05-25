module tea;

import std::core::dstring;

// ViewBuf is a string builder for constructing View content.
// It wraps DString with chaining methods for ergonomic view building.
// 
// Example:
//   ViewBuf buf = new_view_buf();
//   buf.write(title.render("Hello")).writeln("").write(content);
//   return tea::new_view(buf.str());
struct ViewBuf {
	DString ds;
}

// new_view_buf creates a ViewBuf backed by the temp allocator.
fn ViewBuf new_view_buf() {
	return { .ds = dstring::temp() };
}

// write appends a string and returns self for chaining.
fn ViewBuf* ViewBuf.write(ViewBuf* self, String s) {
	self.ds.append_string(s);
	return self;
}

// writeln appends a string followed by a newline.
fn ViewBuf* ViewBuf.writeln(ViewBuf* self, String s) {
	self.ds.append_string(s);
	self.ds.append_char('\n');
	return self;
}

// writec appends a single character.
fn ViewBuf* ViewBuf.writec(ViewBuf* self, char c) {
	self.ds.append_char(c);
	return self;
}

// writef appends a formatted string.
fn ViewBuf* ViewBuf.writef(ViewBuf* self, String fmt, args...) {
	self.ds.append_string(string::tformat(fmt, ...args));
	return self;
}

// str returns the accumulated string content.
fn String ViewBuf.str(ViewBuf* self) => self.ds.str_view();