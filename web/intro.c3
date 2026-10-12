struct Counter {
  sz value;
}

fn milktea::Cmd Counter.update(&self, milktea::Msg msg) @dynamic {
  switch (msg.key.code) {
    case UP: self.value++;
    case DOWN: self.value--;
    case ESC: return milktea::quit();
    default:
  }
  return null;
}

fn milktea::Node* Counter.view(&self) @dynamic {
  glaze::Style box = glaze::style()
    .foreground(glaze::color_hex("#00d7ff"))
    .with_bold(true).padding(1, 3, 1, 3)
    .with_border(glaze::ROUNDED);
  String content = string::tformat("Counter: %d", self.value);
  return milktea::root()
    .add(milktea::text(box.render(content)).center());
}
