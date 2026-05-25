module jsrt;

extern fn void* jsrt_new_runtime();
extern fn void* jsrt_new_context(void* rt);
extern fn void jsrt_free(void* rt, void* ctx);
extern fn int jsrt_eval(void* ctx, ZString src, sz len, ZString filename);
extern fn void* jsrt_get_global(void* ctx);
extern fn void* jsrt_get_prop(void* ctx, void* obj, ZString name);
extern fn int jsrt_call(void* ctx, void* fn_val, void* this_val, int argc, void** argv, void** out);
extern fn void* jsrt_new_object(void* ctx);
extern fn void* jsrt_new_int32(void* ctx, int val);
extern fn void jsrt_set_prop_str(void* ctx, void* obj, ZString name, ZString val);
extern fn void jsrt_set_prop_str_n(void* ctx, void* obj, ZString name, char* val, sz len);
extern fn void jsrt_set_prop_int(void* ctx, void* obj, ZString name, int val);
extern fn void jsrt_set_prop_bool(void* ctx, void* obj, ZString name, int val);
extern fn void jsrt_set_prop_obj(void* ctx, void* obj, ZString name, void* child);
extern fn ZString jsrt_to_cstring(void* ctx, void* val);
extern fn void jsrt_free_cstring(void* ctx, ZString s);
extern fn int jsrt_is_null(void* ctx, void* val);
extern fn int jsrt_is_function(void* ctx, void* val);
extern fn void jsrt_free_value(void* ctx, void* val);
extern fn void jsrt_set_global_fn(void* ctx, ZString name, void* fn_ptr, int length);
extern fn int jsrt_is_string(void* ctx, void* val);
extern fn int jsrt_is_array(void* ctx, void* val);
extern fn int jsrt_array_length(void* ctx, void* val);
extern fn void* jsrt_array_item(void* ctx, void* val, int idx);

extern fn int jsrt_eval_module(void* rt, void* ctx, ZString src, sz len, ZString filename);
extern fn long jsrt_now_ms();
extern fn ZString jsrt_last_error();
extern fn void jsrt_clear_error();
extern fn void jsrt_execute_pending_jobs(void* rt);
extern fn int jsrt_set_timeout(void* ctx, void* callback_val, long delay_ms);
extern fn void jsrt_clear_timeout(void* ctx, int timer_id);
extern fn void jsrt_run_timers(void* rt, void* ctx);
extern fn void jsrt_fetch_init();
extern fn void jsrt_drain_fetch_responses(void* rt, void* ctx);
extern fn void jsrt_register_async_globals(void* ctx);
extern fn long jsrt_next_timer_ms();
extern fn int jsrt_has_pending_fetch();
extern fn int jsrt_is_job_pending(void* rt);

faultdef JS_ERROR;

struct Runtime {
	void* rt;
	void* ctx;
}

fn Runtime? new_runtime() {
	void* rt = jsrt_new_runtime();
	if (!rt) return JS_ERROR~;

	void* ctx = jsrt_new_context(rt);
	if (!ctx) {
		jsrt_free(rt, null);
		return JS_ERROR~;
	}

	return { .rt = rt, .ctx = ctx };
}

fn void Runtime.free(&self) {
	jsrt_free(self.rt, self.ctx);
}

fn bool Runtime.eval(&self, String src) {
	int result = jsrt_eval(self.ctx, (ZString)src.ptr, src.len, "<input>");
	return result == 0;
}

fn bool Runtime.eval_module(&self, String src, String filename) {
	int result = jsrt_eval_module(self.rt, self.ctx, (ZString)src.ptr, src.len, (ZString)filename.ptr);
	return result == 0;
}

fn bool Runtime.is_module(&self, String src) @inline {
	// Detect ES module: starts with import/export, or has one after a newline
	if (src.starts_with("import ") || src.starts_with("export ")) return true;
	if (src.contains("\nimport ") || src.contains("\nexport ")) return true;
	return false;
}

fn void* Runtime.get_global(&self) {
	return jsrt_get_global(self.ctx);
}

fn void* Runtime.get_prop(&self, void* obj, String name) {
	return jsrt_get_prop(self.ctx, obj, (ZString)name.ptr);
}

fn void* Runtime.get_global_prop(&self, String name) {
	void* global = self.get_global();
	if (!global) return null;
	void* result = self.get_prop(global, name);
	self.free_value(global);
	return result;
}

fn void* Runtime.call0(&self, void* fn_val, void* this_val) {
	void* result = null;
	int status   = jsrt_call(self.ctx, fn_val, this_val, 0, null, &result);
	if (status != 0) return null;
	return result;
}

fn void* Runtime.call1(&self, void* fn_val, void* this_val, void* arg) {
	void* result = null;
	void*[] argv = { arg };
	int status   = jsrt_call(self.ctx, fn_val, this_val, 1, &argv[0], &result);
	if (status != 0) return null;
	return result;
}

fn void* Runtime.new_object(&self) {
	return jsrt_new_object(self.ctx);
}

fn void* Runtime.new_int32(&self, int val) {
	return jsrt_new_int32(self.ctx, val);
}

fn void* Runtime.call2(&self, void* fn_val, void* this_val, void* a0, void* a1) {
	void* result = null;
	void*[] argv = { a0, a1 };
	int status   = jsrt_call(self.ctx, fn_val, this_val, 2, &argv[0], &result);
	if (status != 0) return null;
	return result;
}

fn void* Runtime.call3(&self, void* fn_val, void* this_val, void* a0, void* a1, void* a2) {
	void* result = null;
	void*[] argv = { a0, a1, a2 };
	int status   = jsrt_call(self.ctx, fn_val, this_val, 3, &argv[0], &result);
	if (status != 0) return null;
	return result;
}

fn void Runtime.set_prop_str(&self, void* obj, String name, String val) {
	jsrt_set_prop_str_n(self.ctx, obj, (ZString)name.ptr, val.ptr, val.len);
}

fn void Runtime.set_prop_int(&self, void* obj, String name, int val) {
	jsrt_set_prop_int(self.ctx, obj, (ZString)name.ptr, val);
}

fn void Runtime.set_prop_bool(&self, void* obj, String name, bool val) {
	jsrt_set_prop_bool(self.ctx, obj, (ZString)name.ptr, (int)val);
}

fn void Runtime.set_prop_obj(&self, void* obj, String name, void* child) {
	jsrt_set_prop_obj(self.ctx, obj, (ZString)name.ptr, child);
}

fn String Runtime.to_string(&self, void* val) {
	ZString cstr = jsrt_to_cstring(self.ctx, val);
	if (!cstr) return "";
	return cstr.str_view();
}

fn void Runtime.free_cstring(&self, ZString s) {
	jsrt_free_cstring(self.ctx, s);
}

fn bool Runtime.is_null(&self, void* val) {
	return jsrt_is_null(self.ctx, val) != 0;
}

fn bool Runtime.is_function(&self, void* val) {
	return jsrt_is_function(self.ctx, val) != 0;
}

fn void Runtime.free_value(&self, void* val) {
	jsrt_free_value(self.ctx, val);
}

fn bool Runtime.is_string(&self, void* val) {
	return jsrt_is_string(self.ctx, val) != 0;
}

fn bool Runtime.is_array(&self, void* val) {
	return jsrt_is_array(self.ctx, val) != 0;
}

fn int Runtime.array_length(&self, void* val) {
	return jsrt_array_length(self.ctx, val);
}

fn void* Runtime.array_item(&self, void* val, int idx) {
	return jsrt_array_item(self.ctx, val, idx);
}

fn void Runtime.execute_jobs(&self) {
	jsrt_execute_pending_jobs(self.rt);
}

fn void Runtime.run_timers(&self) {
	jsrt_run_timers(self.rt, self.ctx);
}

fn void Runtime.drain_fetch(&self) {
	jsrt_drain_fetch_responses(self.rt, self.ctx);
}

fn void Runtime.register_globals(&self) {
	jsrt_register_async_globals(self.ctx);
}

// next_timer_ms returns ms until the soonest JS setTimeout fires, or -1 if none.
fn long Runtime.next_timer_ms(&self) {
	return jsrt_next_timer_ms();
}

// has_pending_fetch returns true if any fetch() responses are waiting to be drained.
fn bool Runtime.has_pending_fetch(&self) {
	return jsrt_has_pending_fetch() != 0;
}

// is_job_pending returns true if QuickJS has unprocessed microtasks (Promise continuations).
fn bool Runtime.is_job_pending(&self) {
	return jsrt_is_job_pending(self.rt) != 0;
}