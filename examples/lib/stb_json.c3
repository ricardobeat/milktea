module stb_json;

const int STBJ_OBJECT = 0;
const int STBJ_ARRAY  = 1;
const int STBJ_ERROR  = 2;

struct Cursor {
	int type;
	uint len;
	char* buffer;
	char* cursor;
	char error;
}

extern fn int stbj_any_error(Cursor* ctx);
extern fn char* stbj_get_last_error(Cursor* ctx);
extern fn Cursor stbj_load_buffer(char* buffer, uint len);
extern fn int stbj_count_values(Cursor* ctx);
extern fn Cursor stbj_move_cursor_index(Cursor* ctx, int index);
extern fn Cursor stbj_move_cursor_name(Cursor* ctx, char* name);
extern fn int stbj_read_int_index(Cursor* ctx, int index, int default_value);
extern fn int stbj_read_int_name(Cursor* ctx, char* name, int default_value);
extern fn double stbj_read_double_index(Cursor* ctx, int index, double default_value);
extern fn double stbj_read_double_name(Cursor* ctx, char* name, double default_value);
extern fn int stbj_read_string_index(Cursor* ctx, int index, char* buf, int bufsz, char* default_value);
extern fn int stbj_read_string_name(Cursor* ctx, char* name, char* buf, int bufsz, char* default_value);