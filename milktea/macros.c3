module milktea;

import std::io;

// @program creates a Program from a model pointer, handling the
// unsafe (Model) cast internally. This eliminates the most common
// source of errors in Bubble Tea programs.
// 
// Example:
//   Counter c = {};
//   Program p = milktea::@program(&c);
//   if (catch err = p.run()) { ... }
macro @program(#model) {
	Program p = { .model = (Model)#model };
	return p;
}

// @run_program is a convenience macro that creates and runs a Program.
// It combines @program() and Program.run() in one call.
// 
// Example:
//   Counter c = {};
//   if (catch err = milktea::@run_program(&c)) {
//       io::printfn("Error: %s", err);
//   }
macro @run_program(#model) {
	Program p = { .model = (Model)#model };
	return p.run();
}

// @run creates a Program, runs it, and handles errors by printing to stderr.
// Returns 0 on success, 1 on error. Use this as the one-liner main body.
//
// Example:
//   fn int main() {
//       Counter c = {};
//       return milktea::@run(&c);
//   }
macro @run(#model) {
	Program p = { .model = (Model)#model };
	if (catch err = p.run()) {
		io::eprintfn("Error: %s", err);
		return 1;
	}
	return 0;
}

// @test_program creates a Program in test mode with a capture buffer,
// injects a window size, and optionally loads input bytes. Returns the
// Program so the caller can send messages and run it.
// 
// Example:
//   Counter c = {};
//   DString out = dstring::new();
//   Program p = milktea::@test_program(&c, &out, 80, 24);
//   p.send({ .kind = MsgKind.QUIT });
//   p.run();
macro @test_program(#model, #output, #w, #h) {
	Program p = { .model = (Model)#model };
	with_test_mode(&p, #output);
	with_window_size(&p, #w, #h);
	return p;
}

// @test_program_input creates a Program in test mode with input data.
// The program will consume the input bytes, then process any Send()-
// injected messages.
// 
// Example:
//   Counter c = {};
//   DString out = dstring::new();
//   Program p = milktea::@test_program_input(&c, &out, 80, 24, "q");
//   p.run();
macro @test_program_input(#model, #output, #w, #h, #input) {
	var p = @test_program(#model, #output, #w, #h);
	with_input(&p, #input);
	return p;
}