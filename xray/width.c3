module xray;
import utf8;

// char_width is the number of terminal columns a codepoint takes: 0, 1 or 2.
// See utf8::width.
fn sz char_width(uint cp) => utf8::width(cp);
