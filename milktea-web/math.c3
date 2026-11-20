module milktea @feat(MILKTEA_WEB);

// Use the browser's math library instead of freestanding argument reduction.
extern fn double browser_sin(double x) @wasm("milktea", "math_sin");
extern fn double browser_cos(double x) @wasm("milktea", "math_cos");
fn float browser_sinf(float x) @cname("sinf") @nostrip { return (float)browser_sin((double)x); }
fn float browser_cosf(float x) @cname("cosf") @nostrip { return (float)browser_cos((double)x); }
fn double browser_sin_impl(double x) @cname("sin") @nostrip { return browser_sin(x); }
fn double browser_cos_impl(double x) @cname("cos") @nostrip { return browser_cos(x); }
