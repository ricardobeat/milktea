module http_shim;

// Resp mirrors the C `struct resp` in http_shim.c — keep field order/types aligned.
struct Resp {
	int status;
	char* body;
	int len;
}

// StreamCb is called for each SSE data chunk. Return non-zero to cancel.
alias StreamCb = fn int(char* data, int len, void* user);

extern fn void mimo_global_init();
extern fn int mimo_http_post(ZString url, ZString auth, ZString body, int timeout_ms, Resp* out);
extern fn int mimo_http_post_stream(ZString url, ZString auth, ZString body, int timeout_ms, StreamCb cb, void* user, int* out_status);
extern fn void mimo_free(void* p);
extern fn int mimo_run_command(char* cmd, char* outbuf, int outsize, int* exit_code);
