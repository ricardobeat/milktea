struct Counter { sz count; }

fn milktea::Cmd Counter.update(&self, milktea::Msg msg) @dynamic {
  if (msg.kind == milktea::MsgKind.KEY &&
      msg.key.code == milktea::KeyCode.UP) self.count++;
  return null;
}

fn milktea::Node* Counter.view(&self) @dynamic {
  String label = string::tformat("Count: %d", self.count);
  return milktea::text(label, glaze::style()
    .foreground(glaze::color_hex("#a8d5ba"))
    .with_border(glaze::ROUNDED)
    .padding(1, 2, 1, 2));
}
