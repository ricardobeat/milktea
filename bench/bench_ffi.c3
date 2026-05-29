module bench_ffi;
import taro;
import std::io;
import std::core::mem;

const int N = 1000;

fn int main(String[] args) {
	io::printfn("bench: %d FFI calls", N);

	Runtime? rt_opt = taro::new_runtime();
	if (catch err = rt_opt) { io::eprintfn("failed to create runtime"); return 1; }
	Runtime rt = rt_opt;
	defer rt.free();

	void* ctx = rt.ctx;
	rt.register_globals();

	// Eval a trivial JS function
	if (!rt.eval("function noop(a, b) { return a; }")) {
		io::eprintfn("eval failed"); return 1;
	}
	void* global = rt.get_global();
	void* fn_val = rt.get_prop(global, "noop");
	rt.free_value(global);
	if (!fn_val || !rt.is_function(fn_val)) {
		io::eprintfn("noop not found"); return 1;
	}

	// Benchmark 1: new_int32 + free_value
	long t0 = taro::taro_now_ms();
	for (int i = 0; i < N; i++) {
		void* v = rt.new_int32(i);
		rt.free_value(v);
	}
	long t1 = taro::taro_now_ms();
	io::printfn("new+free int32:  %dms (%d calls, %.1fμs each)", t1 - t0, N, (double)(t1 - t0) * 1000.0 / N);

	// Benchmark 2: call2 with trivial function (returns arg)
	void* undef = null;
	void* a = rt.new_int32(42);
	void* b = rt.new_int32(99);
	long t2 = taro::taro_now_ms();
	for (int i = 0; i < N; i++) {
		void* result = rt.call2(fn_val, undef, a, b);
		if (result) rt.free_value(result);
	}
	long t3 = taro::taro_now_ms();
	io::printfn("call2 (noop):    %dms (%d calls, %.1fμs each)", t3 - t2, N, (double)(t3 - t2) * 1000.0 / N);
	rt.free_value(a);
	rt.free_value(b);

	// Benchmark 3: Eval a function that creates Uint8Array and returns it
	if (!rt.eval("function make_u8(w) { var b = new Uint8Array(w * 6); for (var i = 0; i < b.length; i++) b[i] = i & 0xff; return b; }")) {
		io::eprintfn("eval make_u8 failed"); return 1;
	}
	void* global2 = rt.get_global();
	void* fn_u8 = rt.get_prop(global2, "make_u8");
	rt.free_value(global2);
	if (!fn_u8 || !rt.is_function(fn_u8)) {
		io::eprintfn("make_u8 not found"); return 1;
	}

	void* w_arg = rt.new_int32(80);
	long t4 = taro::taro_now_ms();
	for (int i = 0; i < N; i++) {
		void* result = rt.call2(fn_u8, undef, w_arg, null);
		if (result && rt.is_uint8_array(result)) {
			char[] data = rt.get_uint8_array_data(result);
			(void)data.len;
		}
		if (result) rt.free_value(result);
	}
	long t5 = taro::taro_now_ms();
	io::printfn("call2+u8+read:   %dms (%d calls, %.1fμs each)", t5 - t4, N, (double)(t5 - t4) * 1000.0 / N);
	rt.free_value(w_arg);

	// Benchmark 4: Full per-row simulation (like doom-fire draw handler)
	// Create 48 rows, each calling make_u8 and reading the result
	long t6 = taro::taro_now_ms();
	for (int i = 0; i < N; i++) {
		for (int r = 0; r < 48; r++) {
			void* ww = rt.new_int32(80);
			void* rr = rt.new_int32(r);
			void* result = rt.call2(fn_u8, undef, ww, rr);
			if (ww) rt.free_value(ww);
			if (rr) rt.free_value(rr);
			if (result && rt.is_uint8_array(result)) {
				char[] data = rt.get_uint8_array_data(result);
				(void)data.len;
			}
			if (result) rt.free_value(result);
		}
	}
	long t7 = taro::taro_now_ms();
	double per_frame = (double)(t7 - t6) / N;
	io::printfn("48-row sim:      %dms (%d frames, %.1fms/frame)", t7 - t6, N, per_frame);

	rt.free_value(fn_val);
	rt.free_value(fn_u8);
	return 0;
}
