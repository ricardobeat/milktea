struct Counter { sz value; }

fn milktea::Cmd Counter.update(&self, milktea::Msg msg) @dynamic {
  if (msg.kind == milktea::MsgKind.KEY &&
      msg.key.code == milktea::KeyCode.UP) self.value++;
  return null;
}

fn milktea::Node* Counter.view(Counter* self) @dynamic {
	glaze::Style box = glaze::style()
		.foreground(glaze::color_hex("#00d7ff"))
		.with_bold(true)
		.padding(1, 3, 1, 3)
		.with_border(glaze::ROUNDED);

	String label   = string::tformat("Counter: %d", self.value);
	String hint    = "\nUse ↑↓ to change, q to quit";
	String content = string::tformat("%s%s", label, hint);
	return milktea::root()
		.add(milktea::text(box.render(content)).center());
}
