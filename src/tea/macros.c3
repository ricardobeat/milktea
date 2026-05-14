module tea;

// @program creates a Program from a model pointer, handling the
// unsafe (Model) cast internally. This eliminates the most common
// source of errors in milktea programs.
//
// Example:
//   Counter c = {};
//   Program p = tea::@program(&c);
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
//   if (catch err = tea::@run_program(&c)) {
//       io::printfn("Error: %s", err);
//   }
macro @run_program(#model) {
    var p = @program(#model);
    return p.run();
}

// @test_program creates a Program in test mode with a capture buffer,
// injects a window size, and optionally loads input bytes. Returns the
// Program so the caller can send messages and run it.
//
// Example:
//   Counter c = {};
//   DString out = dstring::new();
//   Program p = tea::@test_program(&c, &out, 80, 24);
//   p.send({ .kind = MsgKind.QUIT });
//   p.run();
macro @test_program(#model, #output, #w, #h) {
    var p = @program(#model);
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
//   Program p = tea::@test_program_input(&c, &out, 80, 24, "q");
//   p.run();
macro @test_program_input(#model, #output, #w, #h, #input) {
    var p = @test_program(#model, #output, #w, #h);
    with_input(&p, #input);
    return p;
}
