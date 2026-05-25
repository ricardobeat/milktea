#include "../../vendor/quickjs/quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <pthread.h>
#include <curl/curl.h>
#include <libgen.h>   /* dirname */
#include <limits.h>   /* PATH_MAX */
#include <sys/stat.h> /* stat, mkdir */
#include <dirent.h>   /* opendir, readdir, closedir */
#include <unistd.h>   /* unlink */

/*
 * jsrt.c - Thin C shim over the QuickJS C API
 *
 * All JSValue* returned are malloc'd with malloc(), freed with jsrt_free_value().
 * This allows the C3 side to work with opaque void* handles and never touch
 * JSValue or JSRuntime directly.
 */

/* Last JS error message + stack, cleared on successful call */
static char _jsrt_last_error[4096] = {0};

const char* jsrt_last_error(void) {
    return _jsrt_last_error[0] ? _jsrt_last_error : NULL;
}

void jsrt_clear_error(void) {
    _jsrt_last_error[0] = 0;
}

/* Heap-allocate a JSValue and return it as void* */
static void* _jsrt_alloc_value(JSValue val) {
    JSValue* ptr = (JSValue*)malloc(sizeof(JSValue));
    if (!ptr) return NULL;
    *ptr = val;
    return ptr;
}

/* ============================================================
 * ES Module loader
 * ============================================================ */

/* Source for the "tea" module — re-exports everything from globalThis so that
   both script-mode (counter.js) and module-mode (import { tea } from "tea")
   users share the same runtime objects. */
static const char _tea_module_src[] =
    "export const tea = globalThis.tea;\n"
    "export const h   = globalThis.h;\n";

/* "fs" module — Bun-compatible file I/O API */
static const char _fs_module_src[] =
    "function file(path) {\n"
    "  path = String(path);\n"
    "  const f = {\n"
    "    get path() { return path; },\n"
    "    get name() { const p = path; const i = p.lastIndexOf('/'); return i >= 0 ? p.slice(i+1) : p; },\n"
    "    get size() { return __fs_size(path); },\n"
    "    get type() {\n"
    "      const ext = (path.lastIndexOf('.') >= 0) ? path.slice(path.lastIndexOf('.')).toLowerCase() : '';\n"
    "      const m = {'.txt':'text/plain','.json':'application/json','.js':'text/javascript','.ts':'text/javascript',\n"
    "        '.html':'text/html','.css':'text/css','.xml':'text/xml','.csv':'text/csv','.md':'text/markdown',\n"
    "        '.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.webp':'image/webp',\n"
    "        '.svg':'image/svg+xml','.pdf':'application/pdf','.zip':'application/zip','.gz':'application/gzip',\n"
    "        '.wasm':'application/wasm','.bin':'application/octet-stream'};\n"
    "      return m[ext] || 'application/octet-stream';\n"
    "    },\n"
    "    exists()   { return __fs_exists(path); },\n"
    "    text()     { return __fs_read_text(path); },\n"
    "    json()     { const t = __fs_read_text(path); return t == null ? null : JSON.parse(t); },\n"
    "    bytes()    { return __fs_read_bytes(path); },\n"
    "    isFile()   { return __fs_is_file(path); },\n"
    "    isDir()    { return __fs_is_dir(path); },\n"
    "  };\n"
    "  return f;\n"
    "}\n"
    "\n"
    "function write(dest, data) {\n"
    "  if (data && typeof data === 'object' && data.path) {\n"
    "    return __fs_copy_file(String(data.path), String(dest));\n"
    "  }\n"
    "  if (data instanceof Uint8Array) {\n"
    "    return __fs_write_bytes(String(dest), data);\n"
    "  }\n"
    "  return __fs_write_text(String(dest), String(data));\n"
    "}\n"
    "\n"
    "export { file, write };\n"
    "export function exists(p)    { return __fs_exists(String(p)); }\n"
    "export function mkdir(p, o)  { return __fs_mkdir(String(p), o && o.recursive); }\n"
    "export function readdir(p)   { return __fs_read_dir(String(p)); }\n"
    "export function unlink(p)    { return __fs_unlink(String(p)); }\n"
    "export function stat(p)      { return __fs_stat(String(p)); }\n";

/* "os" module — pure C module exposing getenv */
static JSValue _os_getenv(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NULL;
    const char* name = JS_ToCString(ctx, argv[0]);
    if (!name) return JS_NULL;
    const char* val = getenv(name);
    JS_FreeCString(ctx, name);
    return val ? JS_NewString(ctx, val) : JS_NULL;
}

static int _os_module_init(JSContext* ctx, JSModuleDef* m) {
    return JS_SetModuleExport(ctx, m, "getenv",
        JS_NewCFunction(ctx, _os_getenv, "getenv", 1));
}

/* Normalize: for built-ins return as-is; for relative paths resolve vs base */
static char* _module_normalize(JSContext* ctx, const char* base_name,
                                const char* name, void* opaque) {
    (void)opaque;
    /* Built-in virtual modules — pass through unchanged */
    if (strcmp(name, "tea") == 0 || strcmp(name, "os") == 0 || strcmp(name, "fs") == 0)
        return js_strdup(ctx, name);

    /* Relative path: resolve against dirname(base_name) */
    if (name[0] == '.' || name[0] == '/') {
        if (name[0] == '/') return js_strdup(ctx, name);
        /* relative */
        char base_copy[PATH_MAX];
        strncpy(base_copy, base_name, sizeof(base_copy) - 1);
        base_copy[sizeof(base_copy) - 1] = '\0';
        char* dir = dirname(base_copy);
        char resolved[PATH_MAX];
        snprintf(resolved, sizeof(resolved), "%s/%s", dir, name);
        return js_strdup(ctx, resolved);
    }
    /* Bare specifier — return as-is (will fail in loader with a clear error) */
    return js_strdup(ctx, name);
}

static JSModuleDef* _module_loader(JSContext* ctx, const char* name, void* opaque) {
    (void)opaque;

    /* ---- "tea" virtual module ---- */
    if (strcmp(name, "tea") == 0) {
        JSValue func = JS_Eval(ctx, _tea_module_src, strlen(_tea_module_src),
                               "tea", JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        if (JS_IsException(func)) return NULL;
        /* Extract the JSModuleDef* from the compiled function */
        JSModuleDef* m = (JSModuleDef*)JS_VALUE_GET_PTR(func);
        /* Don't free func — the runtime owns it now */
        JS_FreeValue(ctx, func);
        return m;
    }

    /* ---- "os" virtual module ---- */
    if (strcmp(name, "os") == 0) {
        JSModuleDef* m = JS_NewCModule(ctx, "os", _os_module_init);
        if (!m) return NULL;
        JS_AddModuleExport(ctx, m, "getenv");
        return m;
    }

    /* ---- "fs" virtual module ---- */
    if (strcmp(name, "fs") == 0) {
        JSValue func = JS_Eval(ctx, _fs_module_src, strlen(_fs_module_src),
                               "fs", JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        if (JS_IsException(func)) return NULL;
        JSModuleDef* m = (JSModuleDef*)JS_VALUE_GET_PTR(func);
        JS_FreeValue(ctx, func);
        return m;
    }

    /* ---- File-based module ---- */
    FILE* f = fopen(name, "rb");
    if (!f) {
        JS_ThrowReferenceError(ctx, "module not found: '%s'", name);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);
    char* buf = (char*)malloc(sz + 1);
    if (!buf) { fclose(f); JS_ThrowOutOfMemory(ctx); return NULL; }
    fread(buf, 1, sz, f);
    fclose(f);
    buf[sz] = '\0';

    JSValue func = JS_Eval(ctx, buf, (size_t)sz, name,
                           JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(buf);
    if (JS_IsException(func)) return NULL;
    JSModuleDef* m = (JSModuleDef*)JS_VALUE_GET_PTR(func);
    JS_FreeValue(ctx, func);
    return m;
}

void* jsrt_new_runtime(void) {
    return JS_NewRuntime();
}

void* jsrt_new_context(void* rt) {
    if (!rt) return NULL;
    JSContext* ctx = JS_NewContext((JSRuntime*)rt);
    if (ctx) {
        JS_SetModuleLoaderFunc((JSRuntime*)rt, _module_normalize, _module_loader, NULL);
    }
    return ctx;
}

void jsrt_free(void* rt, void* ctx) {
    if (ctx) {
        JS_FreeContext((JSContext*)ctx);
    }
    if (rt) {
        JS_FreeRuntime((JSRuntime*)rt);
    }
}

int jsrt_eval(void* ctx, const char* src, size_t len, const char* filename) {
    if (!ctx || !src) return -1;

    JSValue result = JS_Eval((JSContext*)ctx, src, len, filename, JS_EVAL_TYPE_GLOBAL);

    if (JS_IsException(result)) {
        JSContext* c = (JSContext*)ctx;
        JSValue exc = JS_GetException(c);
        const char* exc_str = JS_ToCString(c, exc);
        if (exc_str) {
            fprintf(stderr, "[jsrt] eval error: %s\n", exc_str);
            JS_FreeCString(c, exc_str);
        }
        JS_FreeValue(c, exc);
        JS_FreeValue(c, result);
        return -1;
    }

    JS_FreeValue((JSContext*)ctx, result);
    return 0;
}

/* Eval a script as an ES module (top-level await supported).
   Drains pending jobs after evaluation so module-level Promise chains settle. */
int jsrt_eval_module(void* rt, void* ctx, const char* src, size_t len, const char* filename) {
    if (!ctx || !src) return -1;
    JSContext* c = (JSContext*)ctx;

    /* Compile only first so the module loader fires for all imports */
    JSValue func = JS_Eval(c, src, len, filename,
                           JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(func)) {
        JSValue exc = JS_GetException(c);
        const char* s = JS_ToCString(c, exc);
        if (s) { fprintf(stderr, "[jsrt] module compile error: %s\n", s); JS_FreeCString(c, s); }
        JS_FreeValue(c, exc);
        return -1;
    }

    /* Run the compiled module function */
    JSValue result = JS_EvalFunction(c, func);
    if (JS_IsException(result)) {
        JSValue exc = JS_GetException(c);
        const char* s = JS_ToCString(c, exc);
        if (s) { fprintf(stderr, "[jsrt] module eval error: %s\n", s); JS_FreeCString(c, s); }
        JS_FreeValue(c, exc);
        JS_FreeValue(c, result);
        return -1;
    }
    JS_FreeValue(c, result);

    /* Drain microtasks so all top-level awaits and import side-effects settle */
    JSContext* pctx;
    int r;
    do { r = JS_ExecutePendingJob((JSRuntime*)rt, &pctx); } while (r > 0);

    return 0;
}

void* jsrt_get_global(void* ctx) {
    if (!ctx) return NULL;

    JSValue global = JS_GetGlobalObject((JSContext*)ctx);
    return _jsrt_alloc_value(global);
}

void* jsrt_get_prop(void* ctx, void* obj, const char* name) {
    if (!ctx || !obj || !name) return NULL;

    JSValue obj_val = *(JSValue*)obj;
    JSValue prop_val = JS_GetPropertyStr((JSContext*)ctx, obj_val, name);

    return _jsrt_alloc_value(prop_val);
}

int jsrt_call(void* ctx, void* fn_val, void* this_val, int argc, void** argv, void** out) {
    if (!ctx || !fn_val) return -1;

    JSContext* c = (JSContext*)ctx;
    JSValue fn = *(JSValue*)fn_val;
    JSValue this_v = this_val ? *(JSValue*)this_val : JS_UNDEFINED;

    /* Allocate and fill the argv array */
    JSValue* args = (JSValue*)malloc(sizeof(JSValue) * argc);
    if (!args && argc > 0) return -1;

    for (int i = 0; i < argc; i++) {
        if (argv[i]) {
            args[i] = *(JSValue*)argv[i];
        } else {
            args[i] = JS_UNDEFINED;
        }
    }

    /* Call the function */
    JSValue result = JS_Call(c, fn, this_v, argc, (JSValueConst*)args);

    free(args);

    if (JS_IsException(result)) {
        /* Print and clear the exception so it doesn't poison subsequent calls */
        JSValue exc = JS_GetException(c);
        const char* exc_str = JS_ToCString(c, exc);
        JSValue stack = JS_GetPropertyStr(c, exc, "stack");
        const char* stack_str = !JS_IsUndefined(stack) ? JS_ToCString(c, stack) : NULL;

        /* Store for overlay rendering */
        if (stack_str)
            snprintf(_jsrt_last_error, sizeof(_jsrt_last_error), "%s", stack_str);
        else if (exc_str)
            snprintf(_jsrt_last_error, sizeof(_jsrt_last_error), "%s", exc_str);

        /* Also print to stderr */
        if (exc_str) fprintf(stderr, "\r[jsrt] JS error: %s\r\n", exc_str);
        if (stack_str) {
            const char* p = stack_str;
            while (*p) {
                const char* nl = strchr(p, '\n');
                if (nl) { fprintf(stderr, "\r%.*s\r\n", (int)(nl - p), p); p = nl + 1; }
                else     { fprintf(stderr, "\r%s\r\n", p); break; }
            }
        }

        if (exc_str)   JS_FreeCString(c, exc_str);
        if (stack_str) JS_FreeCString(c, stack_str);
        JS_FreeValue(c, stack);
        JS_FreeValue(c, exc);
        JS_FreeValue(c, result);
        if (out) *out = NULL;
        return -1;
    }

    if (out) {
        *out = _jsrt_alloc_value(result);
    } else {
        JS_FreeValue(c, result);
    }

    return 0;
}

void* jsrt_new_object(void* ctx) {
    if (!ctx) return NULL;

    JSValue obj = JS_NewObject((JSContext*)ctx);
    return _jsrt_alloc_value(obj);
}

void* jsrt_new_int32(void* ctx, int val) {
    if (!ctx) return NULL;
    return _jsrt_alloc_value(JS_NewInt32((JSContext*)ctx, val));
}

void jsrt_set_prop_str(void* ctx, void* obj, const char* name, const char* val) {
    if (!ctx || !obj || !name || !val) return;

    JSContext* c = (JSContext*)ctx;
    JSValue obj_val = *(JSValue*)obj;
    JSValue str_val = JS_NewString(c, val);

    JS_SetPropertyStr(c, obj_val, name, str_val);
}

void jsrt_set_prop_str_n(void* ctx, void* obj, const char* name, const char* val, size_t len) {
    if (!ctx || !obj || !name || !val) return;

    JSContext* c = (JSContext*)ctx;
    JSValue obj_val = *(JSValue*)obj;
    JSValue str_val = JS_NewStringLen(c, val, len);

    JS_SetPropertyStr(c, obj_val, name, str_val);
}

void jsrt_set_prop_int(void* ctx, void* obj, const char* name, int val) {
    if (!ctx || !obj || !name) return;

    JSContext* c = (JSContext*)ctx;
    JSValue obj_val = *(JSValue*)obj;
    JSValue int_val = JS_NewInt32(c, val);

    JS_SetPropertyStr(c, obj_val, name, int_val);
}

void jsrt_set_prop_bool(void* ctx, void* obj, const char* name, int val) {
    if (!ctx || !obj || !name) return;

    JSContext* c = (JSContext*)ctx;
    JSValue obj_val = *(JSValue*)obj;
    JSValue bool_val = JS_NewBool(c, val);

    JS_SetPropertyStr(c, obj_val, name, bool_val);
}

void jsrt_set_prop_obj(void* ctx, void* obj, const char* name, void* child) {
    if (!ctx || !obj || !name || !child) return;

    JSContext* c = (JSContext*)ctx;
    JSValue obj_val = *(JSValue*)obj;
    JSValue child_val = JS_DupValue(c, *(JSValue*)child);
    JS_SetPropertyStr(c, obj_val, name, child_val);
}

char* jsrt_to_cstring(void* ctx, void* val) {
    if (!ctx || !val) return NULL;

    JSContext* c = (JSContext*)ctx;
    JSValue js_val = *(JSValue*)val;

    const char* cstr = JS_ToCString(c, js_val);
    if (!cstr) return NULL;

    /* strdup the string so caller can free independently */
    char* result = (char*)malloc(strlen(cstr) + 1);
    if (result) {
        strcpy(result, cstr);
    }

    JS_FreeCString(c, cstr);

    return result;
}

void jsrt_free_cstring(void* ctx, char* str) {
    (void)ctx;  /* unused */
    if (str) {
        free(str);
    }
}

int jsrt_is_null(void* ctx, void* val) {
    (void)ctx;  /* unused */
    if (!val) return 1;

    JSValue js_val = *(JSValue*)val;

    /* Treat both null and undefined as null */
    return JS_IsNull(js_val) || JS_IsUndefined(js_val);
}

int jsrt_is_function(void* ctx, void* val) {
    if (!ctx || !val) return 0;

    JSValue js_val = *(JSValue*)val;
    return JS_IsFunction((JSContext*)ctx, js_val);
}

void jsrt_free_value(void* ctx, void* val) {
    if (!val) return;

    JSValue js_val = *(JSValue*)val;

    if (ctx) {
        JS_FreeValue((JSContext*)ctx, js_val);
    } else {
        /* If no context, try to free with runtime (less ideal) */
        JS_FreeValueRT(NULL, js_val);
    }

    free(val);
}

typedef void* (*jsrt_cfunc_t)(void* ctx, void* this_val, int argc, void** argv);

typedef struct {
    jsrt_cfunc_t fn;
} jsrt_cfunc_wrapper_t;

static JSValue _jsrt_cfunc_trampoline(JSContext* ctx, JSValueConst this_val,
                                      int argc, JSValueConst* argv,
                                      int magic, JSValue* func_data) {
    (void)magic;  /* unused */

    if (!func_data || func_data[0].tag != JS_TAG_OBJECT) {
        return JS_ThrowInternalError(ctx, "Invalid C function wrapper");
    }

    /* Get the wrapper from opaque data */
    jsrt_cfunc_wrapper_t* wrapper = (jsrt_cfunc_wrapper_t*)JS_GetOpaque(func_data[0], 0);
    if (!wrapper) {
        return JS_ThrowInternalError(ctx, "Invalid C function opaque");
    }

    /* Convert JSValue arguments to void* array */
    void** arg_ptrs = (void**)malloc(sizeof(void*) * argc);
    if (!arg_ptrs && argc > 0) {
        return JS_ThrowOutOfMemory(ctx);
    }

    for (int i = 0; i < argc; i++) {
        JSValue* arg_val = (JSValue*)malloc(sizeof(JSValue));
        if (!arg_val) {
            free(arg_ptrs);
            return JS_ThrowOutOfMemory(ctx);
        }
        *arg_val = (JSValue)argv[i];
        arg_ptrs[i] = arg_val;
    }

    /* Allocate this_val */
    JSValue* this_ptr = (JSValue*)malloc(sizeof(JSValue));
    if (!this_ptr) {
        for (int i = 0; i < argc; i++) {
            free(arg_ptrs[i]);
        }
        free(arg_ptrs);
        return JS_ThrowOutOfMemory(ctx);
    }
    *this_ptr = (JSValue)this_val;

    /* Call the user function */
    JSValue* result_ptr = (JSValue*)wrapper->fn(ctx, this_ptr, argc, arg_ptrs);

    /* Free arguments and this */
    for (int i = 0; i < argc; i++) {
        free(arg_ptrs[i]);
    }
    free(arg_ptrs);
    free(this_ptr);

    /* Get result JSValue and free the wrapper */
    JSValue result = JS_UNDEFINED;
    if (result_ptr) {
        result = *result_ptr;
        free(result_ptr);
    }

    return result;
}

void jsrt_set_global_fn(void* ctx, const char* name, jsrt_cfunc_t fn_ptr, int length) {
    if (!ctx || !name || !fn_ptr) return;

    JSContext* c = (JSContext*)ctx;

    /* Create a wrapper to store the function pointer */
    jsrt_cfunc_wrapper_t* wrapper = (jsrt_cfunc_wrapper_t*)malloc(sizeof(jsrt_cfunc_wrapper_t));
    if (!wrapper) return;

    wrapper->fn = fn_ptr;

    /* Create an object to hold the wrapper via opaque data */
    JSValue wrapper_obj = JS_NewObject(c);
    JS_SetOpaque(wrapper_obj, wrapper);

    /* Create the C function with the wrapper object as data */
    JSValue cfunc = JS_NewCFunctionData(c, _jsrt_cfunc_trampoline, length, 0, 1, &wrapper_obj);

    /* Set the function as a global property */
    JS_SetPropertyStr(c, JS_GetGlobalObject(c), name, cfunc);

    JS_FreeValue(c, wrapper_obj);
}

int jsrt_is_string(void* ctx, void* val) {
    (void)ctx;
    if (!val) return 0;
    JSValue js_val = *(JSValue*)val;
    return JS_IsString(js_val);
}

int jsrt_is_array(void* ctx, void* val) {
    if (!ctx || !val) return 0;
    JSValue js_val = *(JSValue*)val;
    return JS_IsArray((JSContext*)ctx, js_val);
}

int jsrt_array_length(void* ctx, void* val) {
    if (!ctx || !val) return 0;
    JSContext* c = (JSContext*)ctx;
    JSValue js_val = *(JSValue*)val;
    JSValue len_val = JS_GetPropertyStr(c, js_val, "length");
    int len = 0;
    JS_ToInt32(c, &len, len_val);
    JS_FreeValue(c, len_val);
    return len;
}

void* jsrt_array_item(void* ctx, void* val, int idx) {
    if (!ctx || !val) return NULL;
    JSContext* c = (JSContext*)ctx;
    JSValue js_val = *(JSValue*)val;
    JSValue item = JS_GetPropertyUint32(c, js_val, (uint32_t)idx);
    return _jsrt_alloc_value(item);
}

/* ============================================================
 * Monotonic clock
 * ============================================================ */

long long jsrt_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + (long long)ts.tv_nsec / 1000000LL;
}

/* ============================================================
 * Microtask / pending job drain
 * ============================================================ */

void jsrt_execute_pending_jobs(void* rt) {
    if (!rt) return;
    JSContext* pctx;
    int ret;
    do {
        ret = JS_ExecutePendingJob((JSRuntime*)rt, &pctx);
        if (ret < 0 && pctx) {
            JSValue exc = JS_GetException(pctx);
            const char* s = JS_ToCString(pctx, exc);
            if (s) {
                fprintf(stderr, "[jsrt] unhandled promise rejection: %s\n", s);
                JS_FreeCString(pctx, s);
            }
            JS_FreeValue(pctx, exc);
        }
    } while (ret > 0);
}

/* ============================================================
 * Timer queue (setTimeout / clearTimeout)
 * ============================================================ */

#define JSRT_MAX_TIMERS 256

typedef struct {
    int       id;
    long long expiry_ms;
    JSValue   callback;
    int       active;  /* 0 = slot free or cleared */
} jsrt_timer_t;

static jsrt_timer_t _timers[JSRT_MAX_TIMERS];
static int _next_timer_id = 1;
static int _timers_init = 0;

static void _timers_ensure_init(void) {
    if (_timers_init) return;
    memset(_timers, 0, sizeof(_timers));
    for (int i = 0; i < JSRT_MAX_TIMERS; i++) {
        _timers[i].callback = JS_UNDEFINED;
    }
    _timers_init = 1;
}

int jsrt_set_timeout(void* ctx, void* callback_val, long long delay_ms) {
    if (!ctx || !callback_val) return -1;
    _timers_ensure_init();

    JSContext* c = (JSContext*)ctx;
    long long now = jsrt_now_ms();

    for (int i = 0; i < JSRT_MAX_TIMERS; i++) {
        if (!_timers[i].active) {
            _timers[i].id        = _next_timer_id++;
            _timers[i].expiry_ms = now + (delay_ms < 0 ? 0 : delay_ms);
            _timers[i].callback  = JS_DupValue(c, *(JSValue*)callback_val);
            _timers[i].active    = 1;
            return _timers[i].id;
        }
    }
    fprintf(stderr, "[jsrt] timer queue full\n");
    return -1;
}

void jsrt_clear_timeout(void* ctx, int timer_id) {
    if (!ctx || timer_id <= 0) return;
    _timers_ensure_init();
    JSContext* c = (JSContext*)ctx;
    for (int i = 0; i < JSRT_MAX_TIMERS; i++) {
        if (_timers[i].active && _timers[i].id == timer_id) {
            JS_FreeValue(c, _timers[i].callback);
            _timers[i].callback = JS_UNDEFINED;
            _timers[i].active   = 0;
            return;
        }
    }
}

void jsrt_run_timers(void* rt, void* ctx) {
    if (!rt || !ctx) return;
    _timers_ensure_init();
    JSContext* c = (JSContext*)ctx;
    long long now = jsrt_now_ms();

    for (int i = 0; i < JSRT_MAX_TIMERS; i++) {
        if (_timers[i].active && _timers[i].expiry_ms <= now) {
            JSValue cb = _timers[i].callback;
            _timers[i].active   = 0;
            _timers[i].callback = JS_UNDEFINED;

            JSValue result = JS_Call(c, cb, JS_UNDEFINED, 0, NULL);
            JS_FreeValue(c, cb);

            if (JS_IsException(result)) {
                JSValue exc = JS_GetException(c);
                const char* s = JS_ToCString(c, exc);
                if (s) {
                    fprintf(stderr, "[jsrt] timer callback error: %s\n", s);
                    JS_FreeCString(c, s);
                }
                JS_FreeValue(c, exc);
            }
            JS_FreeValue(c, result);
        }
    }
    jsrt_execute_pending_jobs(rt);
}

int jsrt_is_job_pending(void* rt) {
    return rt ? JS_IsJobPending((JSRuntime*)rt) : 0;
}

/* Returns ms until the soonest active timer, or -1 if no timers are active. */
long long jsrt_next_timer_ms(void) {
    _timers_ensure_init();
    long long now = jsrt_now_ms();
    long long soonest = -1;
    for (int i = 0; i < JSRT_MAX_TIMERS; i++) {
        if (_timers[i].active) {
            long long remaining = _timers[i].expiry_ms - now;
            if (remaining < 0) remaining = 0;
            if (soonest < 0 || remaining < soonest) soonest = remaining;
        }
    }
    return soonest;
}

/* ============================================================
 * fetch() — libcurl-based, pthreads, Promise-based
 * ============================================================ */

/* ---- growable byte buffer ---- */
typedef struct { char* buf; size_t len; size_t cap; } _curl_buf_t;

static void _buf_append(_curl_buf_t* b, const char* ptr, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t newcap = b->cap ? b->cap * 2 : 4096;
        while (newcap < b->len + n + 1) newcap *= 2;
        b->buf = (char*)realloc(b->buf, newcap);
        b->cap = newcap;
    }
    if (!b->buf) return;
    memcpy(b->buf + b->len, ptr, n);
    b->len += n;
    b->buf[b->len] = '\0';
}

/* ---- SSE chunk queue (shared across all streaming requests) ---- */
typedef struct jsrt_chunk {
    int      req_id;    /* matches jsrt_fetch_req_t.req_id */
    char*    text;      /* strdup'd chunk text, NULL = stream done */
    int      done;      /* 1 = stream ended (text may be NULL) */
    struct jsrt_chunk* next;
} jsrt_chunk_t;

static pthread_mutex_t _chunk_mutex = PTHREAD_MUTEX_INITIALIZER;
static jsrt_chunk_t*   _chunk_head  = NULL;
static jsrt_chunk_t*   _chunk_tail  = NULL;

static void _chunk_push(jsrt_chunk_t* c) {
    pthread_mutex_lock(&_chunk_mutex);
    c->next = NULL;
    if (_chunk_tail) _chunk_tail->next = c;
    else             _chunk_head = c;
    _chunk_tail = c;
    pthread_mutex_unlock(&_chunk_mutex);
}

static jsrt_chunk_t* _chunk_pop(void) {
    pthread_mutex_lock(&_chunk_mutex);
    jsrt_chunk_t* c = _chunk_head;
    if (c) {
        _chunk_head = c->next;
        if (!_chunk_head) _chunk_tail = NULL;
    }
    pthread_mutex_unlock(&_chunk_mutex);
    return c;
}

/* ---- active streaming request registry ---- */
/* Tracks req_id → active flag only; chunk routing is done via JS globals */
#define JSRT_MAX_STREAMS 16
typedef struct {
    int  req_id;
    int  active;
} jsrt_stream_slot_t;

static jsrt_stream_slot_t _streams[JSRT_MAX_STREAMS];
static pthread_mutex_t    _streams_mutex = PTHREAD_MUTEX_INITIALIZER;
static int                _streams_init  = 0;
static int                _next_req_id   = 1;

static void _streams_ensure_init(void) {
    if (_streams_init) return;
    memset(_streams, 0, sizeof(_streams));
    _streams_init = 1;
}

static int _stream_alloc(void) {
    pthread_mutex_lock(&_streams_mutex);
    _streams_ensure_init();
    for (int i = 0; i < JSRT_MAX_STREAMS; i++) {
        if (!_streams[i].active) {
            _streams[i].req_id = _next_req_id++;
            _streams[i].active = 1;
            int id = _streams[i].req_id;
            pthread_mutex_unlock(&_streams_mutex);
            return id;
        }
    }
    pthread_mutex_unlock(&_streams_mutex);
    return -1;
}

static void _stream_free(int req_id) {
    pthread_mutex_lock(&_streams_mutex);
    for (int i = 0; i < JSRT_MAX_STREAMS; i++) {
        if (_streams[i].active && _streams[i].req_id == req_id) {
            _streams[i].active = 0;
            break;
        }
    }
    pthread_mutex_unlock(&_streams_mutex);
}

/* ---- fetch request struct ---- */
typedef struct {
    char*    url;
    char*    method;
    char*    body;
    char**   headers;
    int      n_headers;
    JSValue  resolve;
    JSValue  reject;
    int      streaming;
    int      req_id;     /* set when streaming=1 */
    JSContext* ctx;
} jsrt_fetch_req_t;

typedef struct jsrt_fetch_resp {
    JSValue  resolve;
    JSValue  reject;
    char*    body;
    size_t   body_len;
    long     status;
    char*    error_msg;
    struct jsrt_fetch_resp* next;
} jsrt_fetch_resp_t;

static pthread_mutex_t _fetch_mutex = PTHREAD_MUTEX_INITIALIZER;
static jsrt_fetch_resp_t* _fetch_resp_head = NULL;
static jsrt_fetch_resp_t* _fetch_resp_tail = NULL;

int jsrt_has_pending_fetch(void) {
    pthread_mutex_lock(&_fetch_mutex);
    int pending = (_fetch_resp_head != NULL);
    pthread_mutex_unlock(&_fetch_mutex);
    if (pending) return 1;
    pthread_mutex_lock(&_chunk_mutex);
    pending = (_chunk_head != NULL);
    pthread_mutex_unlock(&_chunk_mutex);
    if (pending) return 1;
    /* Active stream slots: curl thread is still working */
    pthread_mutex_lock(&_streams_mutex);
    _streams_ensure_init();
    for (int i = 0; i < JSRT_MAX_STREAMS; i++) {
        if (_streams[i].active) { pending = 1; break; }
    }
    pthread_mutex_unlock(&_streams_mutex);
    return pending;
}

static void _fetch_push_resp(jsrt_fetch_resp_t* resp) {
    pthread_mutex_lock(&_fetch_mutex);
    resp->next = NULL;
    if (_fetch_resp_tail) _fetch_resp_tail->next = resp;
    else                  _fetch_resp_head = resp;
    _fetch_resp_tail = resp;
    pthread_mutex_unlock(&_fetch_mutex);
}

static jsrt_fetch_resp_t* _fetch_pop_resp(void) {
    pthread_mutex_lock(&_fetch_mutex);
    jsrt_fetch_resp_t* r = _fetch_resp_head;
    if (r) {
        _fetch_resp_head = r->next;
        if (!_fetch_resp_head) _fetch_resp_tail = NULL;
    }
    pthread_mutex_unlock(&_fetch_mutex);
    return r;
}

/* ---- curl write callbacks ---- */
static size_t _curl_write_batch(char* ptr, size_t size, size_t nmemb, void* ud) {
    size_t n = size * nmemb;
    _buf_append((_curl_buf_t*)ud, ptr, n);
    return n;
}

/* Streaming write: push each SSE line as a chunk */
typedef struct {
    int         req_id;
    _curl_buf_t line_buf;  /* accumulates partial lines */
} _stream_write_ctx_t;

static size_t _curl_write_stream(char* ptr, size_t size, size_t nmemb, void* ud) {
    size_t n = size * nmemb;
    _stream_write_ctx_t* sw = (_stream_write_ctx_t*)ud;
    _buf_append(&sw->line_buf, ptr, n);

    /* Process complete lines from the buffer */
    char* buf = sw->line_buf.buf;
    char* line_start = buf;
    char* p = buf;
    while (*p) {
        if (*p == '\n') {
            *p = '\0';
            /* Trim trailing \r */
            char* end = p - 1;
            while (end >= line_start && *end == '\r') { *end = '\0'; end--; }

            /* Only process "data: ..." lines */
            if (strncmp(line_start, "data: ", 6) == 0) {
                const char* payload = line_start + 6;
                if (strcmp(payload, "[DONE]") != 0 && strlen(payload) > 0) {
                    jsrt_chunk_t* chunk = (jsrt_chunk_t*)calloc(1, sizeof(jsrt_chunk_t));
                    if (chunk) {
                        chunk->req_id = sw->req_id;
                        chunk->text   = strdup(payload);
                        _chunk_push(chunk);
                    }
                }
            }

            line_start = p + 1;
        }
        p++;
    }
    /* Shift remaining partial line to start of buffer */
    size_t remaining = (size_t)(p - line_start);
    if (remaining > 0 && line_start != buf) {
        memmove(buf, line_start, remaining);
        sw->line_buf.len = remaining;
        buf[remaining] = '\0';
    } else if (line_start == p) {
        sw->line_buf.len = 0;
        if (buf) buf[0] = '\0';
    }
    return n;
}

/* ---- fetch thread ---- */
static void _setup_curl_common(CURL* curl, jsrt_fetch_req_t* req,
                               struct curl_slist** hdrs_out) {
    curl_easy_setopt(curl, CURLOPT_URL,            req->url);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT,        60L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT,      "jsrt/1.0");

    struct curl_slist* hdrs = NULL;
    for (int i = 0; i < req->n_headers; i++)
        hdrs = curl_slist_append(hdrs, req->headers[i]);
    if (hdrs) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    *hdrs_out = hdrs;

    const char* method = req->method ? req->method : "GET";
    if (strcmp(method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS,    req->body ? req->body : "");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, req->body ? (long)strlen(req->body) : 0L);
    } else if (strcmp(method, "GET") != 0) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
        if (req->body) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS,    req->body);
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(req->body));
        }
    }
}

static void* _fetch_thread(void* arg) {
    jsrt_fetch_req_t* req = (jsrt_fetch_req_t*)arg;

    CURL* curl = curl_easy_init();
    if (!curl) {
        if (req->streaming) {
            jsrt_chunk_t* done = (jsrt_chunk_t*)calloc(1, sizeof(jsrt_chunk_t));
            if (done) { done->req_id = req->req_id; done->done = 1;
                        done->text = strdup("fetch: curl_easy_init failed"); _chunk_push(done); }
        } else {
            jsrt_fetch_resp_t* resp = (jsrt_fetch_resp_t*)calloc(1, sizeof(jsrt_fetch_resp_t));
            if (resp) { resp->resolve = req->resolve; resp->reject = req->reject;
                        resp->error_msg = strdup("fetch: curl_easy_init failed"); _fetch_push_resp(resp); }
        }
        goto done;
    }

    struct curl_slist* hdrs = NULL;
    _setup_curl_common(curl, req, &hdrs);

    if (req->streaming) {
        _stream_write_ctx_t sw = { .req_id = req->req_id };
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, _curl_write_stream);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA,     &sw);

        CURLcode res = curl_easy_perform(curl);
        if (hdrs) curl_slist_free_all(hdrs);
        free(sw.line_buf.buf);

        /* Push done sentinel with status or error */
        jsrt_chunk_t* sentinel = (jsrt_chunk_t*)calloc(1, sizeof(jsrt_chunk_t));
        if (sentinel) {
            sentinel->req_id = req->req_id;
            sentinel->done   = 1;
            if (res != CURLE_OK) {
                char msg[256];
                snprintf(msg, sizeof(msg), "fetch: %s", curl_easy_strerror(res));
                sentinel->text = strdup(msg);
            }
            _chunk_push(sentinel);
        }
    } else {
        _curl_buf_t body_buf = {0};
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, _curl_write_batch);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA,     &body_buf);

        CURLcode res = curl_easy_perform(curl);
        if (hdrs) curl_slist_free_all(hdrs);

        jsrt_fetch_resp_t* resp = (jsrt_fetch_resp_t*)calloc(1, sizeof(jsrt_fetch_resp_t));
        if (resp) {
            resp->resolve = req->resolve;
            resp->reject  = req->reject;
            if (res != CURLE_OK) {
                char msg[256];
                snprintf(msg, sizeof(msg), "fetch: %s", curl_easy_strerror(res));
                resp->error_msg = strdup(msg);
                free(body_buf.buf);
            } else {
                curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &resp->status);
                resp->body     = body_buf.buf;
                resp->body_len = body_buf.len;
            }
            _fetch_push_resp(resp);
        }
    }

    curl_easy_cleanup(curl);

done:
    for (int i = 0; i < req->n_headers; i++) free(req->headers[i]);
    free(req->headers);
    free(req->url);
    free(req->method);
    free(req->body);
    /* Free JSValue handles stored in req (resolve/reject freed before thread start for streaming,
       or by batch drain for non-streaming) */
    free(req);
    return NULL;
}

void jsrt_fetch_init(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    _streams_ensure_init();
}

/* Called each frame to drain fetch responses and resolve/reject Promises */
void jsrt_drain_fetch_responses(void* rt, void* ctx) {
    if (!ctx) return;
    JSContext* c = (JSContext*)ctx;

    /* ---- Drain streaming chunks via JS globals ---- */
    jsrt_chunk_t* chunk;
    JSValue global = JS_GetGlobalObject(c);
    while ((chunk = _chunk_pop()) != NULL) {
        if (chunk->done) {
            /* __jsrt_stream_done(req_id, error_or_null) */
            JSValue fn = JS_GetPropertyStr(c, global, "__jsrt_stream_done");
            if (JS_IsFunction(c, fn)) {
                JSValue args[2];
                args[0] = JS_NewInt32(c, chunk->req_id);
                args[1] = chunk->text ? JS_NewString(c, chunk->text) : JS_NULL;
                JS_Call(c, fn, JS_UNDEFINED, 2, (JSValueConst*)args);
                JS_FreeValue(c, args[0]);
                JS_FreeValue(c, args[1]);
            }
            JS_FreeValue(c, fn);
            _stream_free(chunk->req_id);
        } else if (chunk->text) {
            /* __jsrt_push_chunk(req_id, text) */
            JSValue fn = JS_GetPropertyStr(c, global, "__jsrt_push_chunk");
            if (JS_IsFunction(c, fn)) {
                JSValue args[2];
                args[0] = JS_NewInt32(c, chunk->req_id);
                args[1] = JS_NewString(c, chunk->text);
                JS_Call(c, fn, JS_UNDEFINED, 2, (JSValueConst*)args);
                JS_FreeValue(c, args[0]);
                JS_FreeValue(c, args[1]);
            }
            JS_FreeValue(c, fn);
        }
        jsrt_execute_pending_jobs(rt);
        if (chunk->text) free(chunk->text);
        free(chunk);
    }
    JS_FreeValue(c, global);

    /* ---- Drain batch responses ---- */
    jsrt_fetch_resp_t* resp;
    while ((resp = _fetch_pop_resp()) != NULL) {
        if (resp->error_msg) {
            JSValue err_str = JS_NewString(c, resp->error_msg);
            JS_Call(c, resp->reject, JS_UNDEFINED, 1, (JSValueConst*)&err_str);
            JS_FreeValue(c, err_str);
            free(resp->error_msg);
        } else {
            /* Build minimal Response object: { ok, status, text(), json() } */
            JSValue response_obj = JS_NewObject(c);
            int ok = (resp->status >= 200 && resp->status < 300);
            JS_SetPropertyStr(c, response_obj, "ok",     JS_NewBool(c, ok));
            JS_SetPropertyStr(c, response_obj, "status", JS_NewInt32(c, resp->status));

            /* text() — returns resolved Promise wrapping body string */
            const char* body_str = resp->body ? resp->body : "";
            JSValue body_jsval = JS_NewString(c, body_str);

            /* Inject a small text()/json() via eval — simpler than C funcs */
            /* We store body on the object and use a getter approach */
            JS_SetPropertyStr(c, response_obj, "_body", body_jsval);

            /* Attach text()/json() via pre-compiled __jsrt_make_response from tea.js */
            JSValue global = JS_GetGlobalObject(c);
            JSValue make_resp_fn = JS_GetPropertyStr(c, global, "__jsrt_make_response");
            JS_FreeValue(c, global);
            if (JS_IsFunction(c, make_resp_fn)) {
                JSValue result = JS_Call(c, make_resp_fn, JS_UNDEFINED, 1, (JSValueConst*)&response_obj);
                JS_FreeValue(c, result);
            }
            JS_FreeValue(c, make_resp_fn);

            JS_Call(c, resp->resolve, JS_UNDEFINED, 1, (JSValueConst*)&response_obj);
            JS_FreeValue(c, response_obj);
            if (resp->body) free(resp->body);
        }
        JS_FreeValue(c, resp->resolve);
        JS_FreeValue(c, resp->reject);
        free(resp);

        jsrt_execute_pending_jobs(rt);
    }
}

/* Direct QuickJS C functions for setTimeout, clearTimeout, fetch */

static JSValue _js_set_timeout(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_NewInt32(ctx, -1);

    long long delay = 0;
    if (argc >= 2) {
        int32_t d = 0;
        JS_ToInt32(ctx, &d, argv[1]);
        delay = (long long)d;
    }

    /* jsrt_set_timeout expects void* pointing to a JSValue; it dups internally */
    int id = jsrt_set_timeout(ctx, (void*)&argv[0], delay);
    return JS_NewInt32(ctx, id);
}

static JSValue _js_clear_timeout(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    int32_t id = 0;
    JS_ToInt32(ctx, &id, argv[0]);
    jsrt_clear_timeout(ctx, (int)id);
    return JS_UNDEFINED;
}

static JSValue _js_fetch(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "fetch: URL required");

    const char* url_cstr = JS_ToCString(ctx, argv[0]);
    if (!url_cstr) return JS_EXCEPTION;

    JSValue resolving_fns[2];
    JSValue promise = JS_NewPromiseCapability(ctx, resolving_fns);
    if (JS_IsException(promise)) {
        JS_FreeCString(ctx, url_cstr);
        return JS_EXCEPTION;
    }

    jsrt_fetch_req_t* req = (jsrt_fetch_req_t*)calloc(1, sizeof(jsrt_fetch_req_t));
    if (!req) {
        JS_FreeCString(ctx, url_cstr);
        JSValue err = JS_NewString(ctx, "fetch: OOM");
        JS_Call(ctx, resolving_fns[1], JS_UNDEFINED, 1, (JSValueConst*)&err);
        JS_FreeValue(ctx, err);
        JS_FreeValue(ctx, resolving_fns[0]);
        JS_FreeValue(ctx, resolving_fns[1]);
        return promise;
    }

    req->url       = strdup(url_cstr);
    req->method    = strdup("GET");
    req->body      = NULL;
    req->streaming = 0;
    req->req_id    = 0;
    req->resolve  = JS_DupValue(ctx, resolving_fns[0]);
    req->reject   = JS_DupValue(ctx, resolving_fns[1]);
    req->ctx      = ctx;
    JS_FreeCString(ctx, url_cstr);
    JS_FreeValue(ctx, resolving_fns[0]);
    JS_FreeValue(ctx, resolving_fns[1]);

    if (argc >= 2 && !JS_IsNull(argv[1]) && !JS_IsUndefined(argv[1])) {
        JSValue opts = argv[1];

        JSValue method_val = JS_GetPropertyStr(ctx, opts, "method");
        if (!JS_IsUndefined(method_val) && !JS_IsNull(method_val)) {
            const char* ms = JS_ToCString(ctx, method_val);
            if (ms) { free(req->method); req->method = strdup(ms); JS_FreeCString(ctx, ms); }
        }
        JS_FreeValue(ctx, method_val);

        JSValue body_val = JS_GetPropertyStr(ctx, opts, "body");
        if (!JS_IsUndefined(body_val) && !JS_IsNull(body_val)) {
            const char* bs = JS_ToCString(ctx, body_val);
            if (bs) { req->body = strdup(bs); JS_FreeCString(ctx, bs); }
        }
        JS_FreeValue(ctx, body_val);

        /* Parse headers: accept plain object { "Key": "Value", ... } */
        JSValue hdrs_val = JS_GetPropertyStr(ctx, opts, "headers");
        if (!JS_IsUndefined(hdrs_val) && !JS_IsNull(hdrs_val)) {
            JSPropertyEnum* props_enum = NULL;
            uint32_t props_count = 0;
            if (JS_GetOwnPropertyNames(ctx, &props_enum, &props_count, hdrs_val,
                                       JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) == 0) {
                req->headers   = (char**)malloc(sizeof(char*) * props_count);
                req->n_headers = 0;
                if (req->headers) {
                    for (uint32_t i = 0; i < props_count; i++) {
                        const char* key = JS_AtomToCString(ctx, props_enum[i].atom);
                        JSValue v = JS_GetProperty(ctx, hdrs_val, props_enum[i].atom);
                        const char* val = JS_ToCString(ctx, v);
                        if (key && val) {
                            /* "Key: Value\0" */
                            size_t len = strlen(key) + 2 + strlen(val) + 1;
                            char* hdr = (char*)malloc(len);
                            if (hdr) {
                                snprintf(hdr, len, "%s: %s", key, val);
                                req->headers[req->n_headers++] = hdr;
                            }
                        }
                        if (key) JS_FreeCString(ctx, key);
                        if (val) JS_FreeCString(ctx, val);
                        JS_FreeValue(ctx, v);
                        JS_FreeAtom(ctx, props_enum[i].atom);
                    }
                    js_free(ctx, props_enum);
                }
            }
        }
        JS_FreeValue(ctx, hdrs_val);

        /* stream: true — enable streaming mode */
        JSValue stream_val = JS_GetPropertyStr(ctx, opts, "stream");
        if (JS_ToBool(ctx, stream_val)) {
            req->streaming = 1;
            req->req_id    = _stream_alloc();
        }
        JS_FreeValue(ctx, stream_val);
    }

    /* For streaming requests: call __jsrt_stream_alloc(req_id) in JS, then
       resolve the promise immediately with a stream response object so the
       caller can start iterating response.body right away. */
    if (req->streaming && req->req_id >= 0) {
        JSValue global = JS_GetGlobalObject(ctx);

        /* __jsrt_stream_alloc(req_id) — sets up the JS-side push queue */
        JSValue alloc_fn = JS_GetPropertyStr(ctx, global, "__jsrt_stream_alloc");
        if (JS_IsFunction(ctx, alloc_fn)) {
            JSValue id_val = JS_NewInt32(ctx, req->req_id);
            JSValue r = JS_Call(ctx, alloc_fn, JS_UNDEFINED, 1, (JSValueConst*)&id_val);
            JS_FreeValue(ctx, id_val);
            JS_FreeValue(ctx, r);
        }
        JS_FreeValue(ctx, alloc_fn);

        /* __jsrt_make_stream_response(req_id, 0) — returns response object with .body */
        JSValue make_fn = JS_GetPropertyStr(ctx, global, "__jsrt_make_stream_response");
        if (JS_IsFunction(ctx, make_fn)) {
            JSValue args[2] = { JS_NewInt32(ctx, req->req_id), JS_NewInt32(ctx, 0) };
            JSValue resp = JS_Call(ctx, make_fn, JS_UNDEFINED, 2, (JSValueConst*)args);
            JS_FreeValue(ctx, args[0]);
            JS_FreeValue(ctx, args[1]);
            /* Resolve the fetch promise with the response */
            JS_Call(ctx, req->resolve, JS_UNDEFINED, 1, (JSValueConst*)&resp);
            JS_FreeValue(ctx, resp);
        }
        JS_FreeValue(ctx, make_fn);
        JS_FreeValue(ctx, global);

        /* resolve/reject are no longer needed by the thread */
        JS_FreeValue(ctx, req->resolve);
        JS_FreeValue(ctx, req->reject);
        req->resolve = JS_UNDEFINED;
        req->reject  = JS_UNDEFINED;
    }

    pthread_t thr;
    if (pthread_create(&thr, NULL, _fetch_thread, req) != 0) {
        JSValue err = JS_NewString(ctx, "fetch: could not create thread");
        JS_Call(ctx, req->reject, JS_UNDEFINED, 1, (JSValueConst*)&err);
        JS_FreeValue(ctx, err);
        JS_FreeValue(ctx, req->reject);
        JS_FreeValue(ctx, req->resolve);
        free(req->url); free(req->method); free(req->body); free(req);
    } else {
        pthread_detach(thr);
    }

    return promise;
}

/* jsrt_set_timeout wrapper for void* callback (used by existing API) */
int jsrt_set_timeout_raw(void* ctx, JSValue cb, long long delay_ms) {
    JSValue* ptr = (JSValue*)malloc(sizeof(JSValue));
    if (!ptr) return -1;
    *ptr = cb;  /* already dup'd by caller */
    int id = jsrt_set_timeout(ctx, ptr, delay_ms);
    free(ptr);  /* jsrt_set_timeout dup'd it internally */
    return id;
}

static JSValue _js_log_stderr(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* s = JS_ToCString(ctx, argv[0]);
    if (s) {
        fprintf(stderr, "%s\n", s);
        JS_FreeCString(ctx, s);
    }
    return JS_UNDEFINED;
}

static JSValue _js_getenv(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NULL;
    const char* name = JS_ToCString(ctx, argv[0]);
    if (!name) return JS_NULL;
    const char* val = getenv(name);
    JS_FreeCString(ctx, name);
    return val ? JS_NewString(ctx, val) : JS_NULL;
}

/* setInterval: re-schedules itself via a wrapper stored in the timer slot */
typedef struct {
    JSContext*  ctx;
    JSValue     callback;
    long long   interval_ms;
    int         id;
    int         active;
} jsrt_interval_t;

#define JSRT_MAX_INTERVALS 64
static jsrt_interval_t _intervals[JSRT_MAX_INTERVALS];
static int _intervals_init = 0;
static int _next_interval_id = 1;

static void _intervals_ensure_init(void) {
    if (_intervals_init) return;
    memset(_intervals, 0, sizeof(_intervals));
    _intervals_init = 1;
}

static void _interval_fire_cb(JSContext* ctx, jsrt_interval_t* iv);

static void* _interval_trampoline_arg = NULL; /* unused, we use ctx stored in slot */

/* Each interval fires its callback then reschedules via setTimeout */
static JSValue _js_interval_trampoline(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val; (void)argc; (void)argv;
    /* Find which interval this belongs to via magic number stored as closure */
    /* We use a per-interval JSValue function that closes over the id */
    /* This is set up in setInterval below */
    return JS_UNDEFINED;
}

/* We implement setInterval in JS-land via tea.js using setTimeout recursion —
   simpler and avoids C-side closure complexity. Expose a basic one here for
   completeness, backed by the same timer queue. */
static JSValue _js_set_interval(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    /* setInterval(fn, delay) — implemented as recursive setTimeout in tea.js;
       this C stub is a fallback that just does one-shot setTimeout for minimal support */
    (void)this_val;
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_NewInt32(ctx, -1);
    long long delay = 0;
    if (argc >= 2) { int32_t d = 0; JS_ToInt32(ctx, &d, argv[1]); delay = d; }
    int id = jsrt_set_timeout(ctx, (void*)&argv[0], delay);
    return JS_NewInt32(ctx, id);
}

/* ── blend_luv JS binding ───────────────────────────────────────────────────── */

typedef struct { unsigned char kind; unsigned char ansi; unsigned char r; unsigned char g; unsigned char b; } LipglossColor;

/* Declared in C3 gradient.c3 with @export — C3 mangles to lipgloss__blend_luv */
extern LipglossColor lipgloss__blend_luv(LipglossColor a, LipglossColor b, double t);

/* Declared in C3 js_view.c3 — C3 mangles as jsrt__function with @export */
extern void*         jsrt__textarea_get_ptr(const char* id);
extern void          jsrt__textarea_handle_key_ptr(void* ta_ptr, int code, int rune, int ctrl, int alt, int shift);
extern void          jsrt__textarea_clear_ptr(void* ta_ptr);
extern int           jsrt__textarea_cursor_row_ptr(void* ta_ptr);
extern int           jsrt__textarea_cursor_col_ptr(void* ta_ptr);
extern const char*   jsrt__textarea_text_ptr(void* ta_ptr);
extern int           jsrt__textarea_text_len(void* ta_ptr);

extern void*         jsrt__viewport_get_ptr(const char* id);
extern void          jsrt__viewport_handle_key_ptr(void* vp_ptr, int code, int ctrl, int alt, int shift);
extern void          jsrt__viewport_scroll_to_bottom_ptr(void* vp_ptr);
extern int           jsrt__viewport_offset_ptr(void* vp_ptr);
extern void          jsrt__viewport_scroll_up_ptr(void* vp_ptr);
extern void          jsrt__viewport_scroll_down_ptr(void* vp_ptr);
extern void          jsrt__viewport_page_up_ptr(void* vp_ptr);
extern void          jsrt__viewport_page_down_ptr(void* vp_ptr);

static int _parse_hex_byte(const char* s) {
    int hi, lo;
    char c = s[0];
    hi = (c >= '0' && c <= '9') ? c-'0' : (c >= 'a' && c <= 'f') ? c-'a'+10 : (c >= 'A' && c <= 'F') ? c-'A'+10 : -1;
    c = s[1];
    lo = (c >= '0' && c <= '9') ? c-'0' : (c >= 'a' && c <= 'f') ? c-'a'+10 : (c >= 'A' && c <= 'F') ? c-'A'+10 : -1;
    if (hi < 0 || lo < 0) return -1;
    return (hi << 4) | lo;
}

static LipglossColor _parse_hex_color(const char* s) {
    LipglossColor c = {0,0,0,0,0};
    if (!s) return c;
    if (s[0] == '#') s++;
    int r = _parse_hex_byte(s);
    int g = _parse_hex_byte(s+2);
    int b = _parse_hex_byte(s+4);
    if (r < 0 || g < 0 || b < 0) return c;
    c.kind = 3; /* TRUECOLOR */
    c.r = (unsigned char)r;
    c.g = (unsigned char)g;
    c.b = (unsigned char)b;
    return c;
}

static JSValue _js_blend_luv(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 3) return JS_UNDEFINED;
    const char* from_str = JS_ToCString(ctx, argv[0]);
    const char* to_str   = JS_ToCString(ctx, argv[1]);
    double t = 0.0;
    JS_ToFloat64(ctx, &t, argv[2]);
    LipglossColor a = _parse_hex_color(from_str);
    LipglossColor b = _parse_hex_color(to_str);
    JS_FreeCString(ctx, from_str);
    JS_FreeCString(ctx, to_str);
    LipglossColor result = lipgloss__blend_luv(a, b, t);
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x",
             (unsigned)result.r, (unsigned)result.g, (unsigned)result.b);
    return JS_NewString(ctx, buf);
}

/* ── textarea JS bridge functions ─────────────────────────────────────────── */

/* Map the string key code produced by keycode_to_string() back to (KeyCode, rune).
   KeyCode enum values: NONE=0,RUNE=1,ENTER=2,BACKSPACE=3,ESC=4,TAB=5,
   UP=6,DOWN=7,LEFT=8,RIGHT=9,HOME=10,END=11,DELETE=12,PAGE_UP=13,PAGE_DOWN=14,
   INSERT=15,F1=16,...F12=27,CTRL_C=28 */
static void _str_to_keycode(const char* s, int32_t* out_code, int32_t* out_rune) {
    *out_rune = 0;
    if (!s || !s[0]) { *out_code = 0; return; }
    if (strcmp(s, "enter")     == 0) { *out_code = 2;  return; }
    if (strcmp(s, "backspace") == 0) { *out_code = 3;  return; }
    if (strcmp(s, "esc")       == 0) { *out_code = 4;  return; }
    if (strcmp(s, "tab")       == 0) { *out_code = 5;  return; }
    if (strcmp(s, "up")        == 0) { *out_code = 6;  return; }
    if (strcmp(s, "down")      == 0) { *out_code = 7;  return; }
    if (strcmp(s, "left")      == 0) { *out_code = 8;  return; }
    if (strcmp(s, "right")     == 0) { *out_code = 9;  return; }
    if (strcmp(s, "home")      == 0) { *out_code = 10; return; }
    if (strcmp(s, "end")       == 0) { *out_code = 11; return; }
    if (strcmp(s, "delete")    == 0) { *out_code = 12; return; }
    if (strcmp(s, "page_up")   == 0) { *out_code = 13; return; }
    if (strcmp(s, "page_down") == 0) { *out_code = 14; return; }
    if (strcmp(s, "insert")    == 0) { *out_code = 15; return; }
    if (strcmp(s, "f1")  == 0) { *out_code = 16; return; }
    if (strcmp(s, "f2")  == 0) { *out_code = 17; return; }
    if (strcmp(s, "f3")  == 0) { *out_code = 18; return; }
    if (strcmp(s, "f4")  == 0) { *out_code = 19; return; }
    if (strcmp(s, "f5")  == 0) { *out_code = 20; return; }
    if (strcmp(s, "f6")  == 0) { *out_code = 21; return; }
    if (strcmp(s, "f7")  == 0) { *out_code = 22; return; }
    if (strcmp(s, "f8")  == 0) { *out_code = 23; return; }
    if (strcmp(s, "f9")  == 0) { *out_code = 24; return; }
    if (strcmp(s, "f10") == 0) { *out_code = 25; return; }
    if (strcmp(s, "f11") == 0) { *out_code = 26; return; }
    if (strcmp(s, "f12") == 0) { *out_code = 27; return; }
    /* single printable character → RUNE */
    if (s[1] == '\0') { *out_code = 1; *out_rune = (int32_t)(unsigned char)s[0]; return; }
    *out_code = 0;
}

static JSValue _js_textarea_update(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 2) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* ta_ptr = jsrt__textarea_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (!ta_ptr) return JS_UNDEFINED;

    JSValue msg = argv[1];
    int32_t code = 0, rune = 0, ctrl = 0, alt = 0, shift = 0;
    JSValue v;
    /* code is a string like "backspace", "enter", "a" — parse it */
    v = JS_GetPropertyStr(ctx, msg, "code");
    const char* code_str = JS_ToCString(ctx, v);
    JS_FreeValue(ctx, v);
    if (code_str) {
        _str_to_keycode(code_str, &code, &rune);
        JS_FreeCString(ctx, code_str);
    }
    v = JS_GetPropertyStr(ctx, msg, "ctrl");   ctrl  = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, msg, "alt");    alt   = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, msg, "shift");  shift = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);

    jsrt__textarea_handle_key_ptr(ta_ptr, code, rune, ctrl, alt, shift);
    return JS_UNDEFINED;
}

static JSValue _js_textarea_get_text(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NewString(ctx, "");
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* ta_ptr = jsrt__textarea_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (!ta_ptr) return JS_NewString(ctx, "");
    int len = jsrt__textarea_text_len(ta_ptr);
    if (len <= 0) return JS_NewString(ctx, "");
    const char* text = jsrt__textarea_text_ptr(ta_ptr);
    return JS_NewStringLen(ctx, text, (size_t)len);
}

static JSValue _js_textarea_clear(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* ta_ptr = jsrt__textarea_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (ta_ptr) jsrt__textarea_clear_ptr(ta_ptr);
    return JS_UNDEFINED;
}

static JSValue _js_viewport_update(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 2) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* vp_ptr = jsrt__viewport_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (!vp_ptr) return JS_UNDEFINED;

    JSValue msg = argv[1];
    const char* code_str = NULL;
    JSValue v = JS_GetPropertyStr(ctx, msg, "code");
    code_str = JS_ToCString(ctx, v);
    JS_FreeValue(ctx, v);

    int32_t code = 0, rune = 0;
    if (code_str) { _str_to_keycode(code_str, &code, &rune); JS_FreeCString(ctx, code_str); }

    int ctrl = 0, alt = 0, shift = 0;
    v = JS_GetPropertyStr(ctx, msg, "ctrl");  ctrl  = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, msg, "alt");   alt   = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, msg, "shift"); shift = JS_ToBool(ctx, v); JS_FreeValue(ctx, v);

    jsrt__viewport_handle_key_ptr(vp_ptr, code, ctrl, alt, shift);
    return JS_UNDEFINED;
}

static JSValue _js_viewport_scroll_to_bottom(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* vp_ptr = jsrt__viewport_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (vp_ptr) jsrt__viewport_scroll_to_bottom_ptr(vp_ptr);
    return JS_UNDEFINED;
}

static JSValue _js_textarea_get_cursor(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    const char* id = NULL;
    if (argc >= 1) {
        id = JS_ToCString(ctx, argv[0]);
        if (!id) return JS_EXCEPTION;
    }
    void* ta_ptr = id ? jsrt__textarea_get_ptr(id) : NULL;
    if (id) JS_FreeCString(ctx, id);
    int row = ta_ptr ? jsrt__textarea_cursor_row_ptr(ta_ptr) : 0;
    int col = ta_ptr ? jsrt__textarea_cursor_col_ptr(ta_ptr) : 0;
    JSValue obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, obj, "row", JS_NewInt32(ctx, row));
    JS_SetPropertyStr(ctx, obj, "col", JS_NewInt32(ctx, col));
    return obj;
}

/* ── viewport scroll JS bridge functions ────────────────────────────────── */

static JSValue _js_viewport_scroll_up(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* vp = jsrt__viewport_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (vp) jsrt__viewport_scroll_up_ptr(vp);
    return JS_UNDEFINED;
}

static JSValue _js_viewport_scroll_down(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* vp = jsrt__viewport_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (vp) jsrt__viewport_scroll_down_ptr(vp);
    return JS_UNDEFINED;
}

static JSValue _js_viewport_page_up(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* vp = jsrt__viewport_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (vp) jsrt__viewport_page_up_ptr(vp);
    return JS_UNDEFINED;
}

static JSValue _js_viewport_page_down(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* id = JS_ToCString(ctx, argv[0]);
    if (!id) return JS_EXCEPTION;
    void* vp = jsrt__viewport_get_ptr(id);
    JS_FreeCString(ctx, id);
    if (vp) jsrt__viewport_page_down_ptr(vp);
    return JS_UNDEFINED;
}

/* ============================================================
 * fs module — C backing functions
 * ============================================================ */

/* __fs_read_text(path) → string | null */
static JSValue _js_fs_read_text(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NULL;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_NULL;

    FILE* f = fopen(path, "rb");
    if (!f) { JS_FreeCString(ctx, path); return JS_NULL; }

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);

    char* buf = (char*)malloc(sz + 1);
    if (!buf) { fclose(f); JS_FreeCString(ctx, path); return JS_NULL; }

    size_t n = fread(buf, 1, sz, f);
    fclose(f);
    buf[n] = '\0';

    JSValue result = JS_NewStringLen(ctx, buf, n);
    free(buf);
    JS_FreeCString(ctx, path);
    return result;
}

/* __fs_write_text(path, data) → boolean */
static JSValue _js_fs_write_text(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 2) return JS_FALSE;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_FALSE;
    const char* data = JS_ToCString(ctx, argv[1]);
    if (!data) { JS_FreeCString(ctx, path); return JS_FALSE; }

    size_t datalen = strlen(data);
    FILE* f = fopen(path, "wb");
    if (!f) { JS_FreeCString(ctx, data); JS_FreeCString(ctx, path); return JS_FALSE; }

    size_t written = fwrite(data, 1, datalen, f);
    fclose(f);
    JS_FreeCString(ctx, data);
    JS_FreeCString(ctx, path);
    return written == datalen ? JS_TRUE : JS_FALSE;
}

/* __fs_write_bytes(path, uint8array) → boolean */
static JSValue _js_fs_write_bytes(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 2) return JS_FALSE;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_FALSE;

    size_t len = 0;
    uint8_t* buf = JS_GetArrayBuffer(ctx, &len, argv[1]);
    if (!buf) {
        /* Try typed array (Uint8Array) */
        size_t byte_offset = 0, byte_length = 0;
        JSValue abuf = JS_GetTypedArrayBuffer(ctx, argv[1], &byte_offset, &byte_length, NULL);
        if (!JS_IsException(abuf)) {
            buf = JS_GetArrayBuffer(ctx, &len, abuf);
            if (buf) { buf += byte_offset; len = byte_length; }
            JS_FreeValue(ctx, abuf);
        }
    }
    if (!buf) { JS_FreeCString(ctx, path); return JS_FALSE; }

    FILE* f = fopen(path, "wb");
    if (!f) { JS_FreeCString(ctx, path); return JS_FALSE; }

    size_t written = fwrite(buf, 1, len, f);
    fclose(f);
    JS_FreeCString(ctx, path);
    return written == len ? JS_TRUE : JS_FALSE;
}

/* __fs_exists(path) → boolean */
static JSValue _js_fs_exists(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_FALSE;
    struct stat st;
    int r = stat(path, &st);
    JS_FreeCString(ctx, path);
    return r == 0 ? JS_TRUE : JS_FALSE;
}

/* __fs_size(path) → number (-1 if not found) */
static JSValue _js_fs_size(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NewInt32(ctx, -1);
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_NewInt32(ctx, -1);
    struct stat st;
    int r = stat(path, &st);
    JS_FreeCString(ctx, path);
    if (r != 0) return JS_NewInt32(ctx, -1);
    return JS_NewInt64(ctx, (int64_t)st.st_size);
}

/* __fs_is_file(path) → boolean */
static JSValue _js_fs_is_file(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_FALSE;
    struct stat st;
    int r = stat(path, &st);
    JS_FreeCString(ctx, path);
    return (r == 0 && S_ISREG(st.st_mode)) ? JS_TRUE : JS_FALSE;
}

/* __fs_is_dir(path) → boolean */
static JSValue _js_fs_is_dir(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_FALSE;
    struct stat st;
    int r = stat(path, &st);
    JS_FreeCString(ctx, path);
    return (r == 0 && S_ISDIR(st.st_mode)) ? JS_TRUE : JS_FALSE;
}

/* __fs_read_json(path) → object | null (handled in JS via JSON.parse) */
/* We don't need a separate C function — the JS module does text() + JSON.parse */

/* __fs_read_bytes(path) → ArrayBuffer | null */
static JSValue _js_fs_read_bytes(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NULL;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_NULL;

    FILE* f = fopen(path, "rb");
    if (!f) { JS_FreeCString(ctx, path); return JS_NULL; }

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);

    uint8_t* buf = (uint8_t*)malloc(sz);
    if (!buf) { fclose(f); JS_FreeCString(ctx, path); return JS_NULL; }

    size_t n = fread(buf, 1, sz, f);
    fclose(f);
    JS_FreeCString(ctx, path);

    /* JS_NewArrayBufferCopy takes ownership of a copy; we free our buf */
    JSValue result = JS_NewArrayBufferCopy(ctx, buf, n);
    free(buf);
    return result;
}

/* __fs_mkdir(path, recursive?) → boolean */
static JSValue _js_fs_mkdir(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_FALSE;

    int recursive = (argc >= 2 && JS_ToBool(ctx, argv[1]));

    if (recursive) {
        /* Create parent directories recursively */
        char tmp[PATH_MAX];
        snprintf(tmp, sizeof(tmp), "%s", path);
        for (char* p = tmp + 1; *p; p++) {
            if (*p == '/') {
                *p = '\0';
                mkdir(tmp, 0755);
                *p = '/';
            }
        }
    }

    int r = mkdir(path, 0755);
    JS_FreeCString(ctx, path);
    return r == 0 ? JS_TRUE : JS_FALSE;
}

/* __fs_unlink(path) → boolean */
static JSValue _js_fs_unlink(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_FALSE;
    int r = unlink(path);
    JS_FreeCString(ctx, path);
    return r == 0 ? JS_TRUE : JS_FALSE;
}

/* __fs_read_dir(path) → string[] | null */
static JSValue _js_fs_read_dir(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NULL;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_NULL;

    DIR* dir = opendir(path);
    if (!dir) { JS_FreeCString(ctx, path); return JS_NULL; }

    JSValue arr = JS_NewArray(ctx);
    uint32_t idx = 0;
    struct dirent* ent;
    while ((ent = readdir(dir)) != NULL) {
        /* Skip . and .. */
        if (ent->d_name[0] == '.' && (ent->d_name[1] == '\0' ||
            (ent->d_name[1] == '.' && ent->d_name[2] == '\0'))) continue;
        JS_SetPropertyUint32(ctx, arr, idx++, JS_NewString(ctx, ent->d_name));
    }
    closedir(dir);
    JS_FreeCString(ctx, path);
    return arr;
}

/* __fs_copy_file(src, dest) → boolean */
static JSValue _js_fs_copy_file(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 2) return JS_FALSE;
    const char* src = JS_ToCString(ctx, argv[0]);
    if (!src) return JS_FALSE;
    const char* dest = JS_ToCString(ctx, argv[1]);
    if (!dest) { JS_FreeCString(ctx, src); return JS_FALSE; }

    FILE* in = fopen(src, "rb");
    if (!in) { JS_FreeCString(ctx, src); JS_FreeCString(ctx, dest); return JS_FALSE; }
    FILE* out = fopen(dest, "wb");
    if (!out) { fclose(in); JS_FreeCString(ctx, src); JS_FreeCString(ctx, dest); return JS_FALSE; }

    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        fwrite(buf, 1, n, out);
    }
    fclose(in);
    fclose(out);
    JS_FreeCString(ctx, src);
    JS_FreeCString(ctx, dest);
    return JS_TRUE;
}

/* __fs_stat(path) → { size, isFile, isDir, mtimeMs } | null */
static JSValue _js_fs_stat(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_NULL;
    const char* path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_NULL;

    struct stat st;
    int r = stat(path, &st);
    JS_FreeCString(ctx, path);
    if (r != 0) return JS_NULL;

    JSValue obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, obj, "size",    JS_NewInt64(ctx, (int64_t)st.st_size));
    JS_SetPropertyStr(ctx, obj, "isFile",  S_ISREG(st.st_mode) ? JS_TRUE : JS_FALSE);
    JS_SetPropertyStr(ctx, obj, "isDir",   S_ISDIR(st.st_mode) ? JS_TRUE : JS_FALSE);
#if defined(__APPLE__)
    JS_SetPropertyStr(ctx, obj, "mtimeMs", JS_NewInt64(ctx, (int64_t)st.st_mtimespec.tv_sec * 1000 + st.st_mtimespec.tv_nsec / 1000000));
#else
    JS_SetPropertyStr(ctx, obj, "mtimeMs", JS_NewInt64(ctx, (int64_t)st.st_mtim.tv_sec * 1000 + st.st_mtim.tv_nsec / 1000000));
#endif
    return obj;
}

void jsrt_register_async_globals(void* ctx) {
    if (!ctx) return;
    JSContext* c = (JSContext*)ctx;
    JSValue global = JS_GetGlobalObject(c);
    JS_SetPropertyStr(c, global, "setTimeout",    JS_NewCFunction(c, _js_set_timeout,    "setTimeout",    2));
    JS_SetPropertyStr(c, global, "clearTimeout",  JS_NewCFunction(c, _js_clear_timeout,  "clearTimeout",  1));
    JS_SetPropertyStr(c, global, "setInterval",   JS_NewCFunction(c, _js_set_interval,   "setInterval",   2));
    JS_SetPropertyStr(c, global, "clearInterval", JS_NewCFunction(c, _js_clear_timeout,  "clearInterval", 1));
    JS_SetPropertyStr(c, global, "fetch",         JS_NewCFunction(c, _js_fetch,          "fetch",         1));
    JS_SetPropertyStr(c, global, "__jsrt_log",    JS_NewCFunction(c, _js_log_stderr,     "__jsrt_log",    1));
    JS_SetPropertyStr(c, global, "blendLuv",          JS_NewCFunction(c, _js_blend_luv,          "blendLuv",          3));
    JS_SetPropertyStr(c, global, "textareaUpdate",     JS_NewCFunction(c, _js_textarea_update,     "textareaUpdate",     2));
    JS_SetPropertyStr(c, global, "textareaGetText",    JS_NewCFunction(c, _js_textarea_get_text,   "textareaGetText",    1));
    JS_SetPropertyStr(c, global, "textareaClear",      JS_NewCFunction(c, _js_textarea_clear,      "textareaClear",      1));
    JS_SetPropertyStr(c, global, "textareaGetCursor",  JS_NewCFunction(c, _js_textarea_get_cursor, "textareaGetCursor",  1));
    JS_SetPropertyStr(c, global, "viewportUpdate",         JS_NewCFunction(c, _js_viewport_update,         "viewportUpdate",         2));
    JS_SetPropertyStr(c, global, "viewportScrollToBottom", JS_NewCFunction(c, _js_viewport_scroll_to_bottom, "viewportScrollToBottom", 1));
    JS_SetPropertyStr(c, global, "viewportScrollUp",       JS_NewCFunction(c, _js_viewport_scroll_up,       "viewportScrollUp",       1));
    JS_SetPropertyStr(c, global, "viewportScrollDown",     JS_NewCFunction(c, _js_viewport_scroll_down,     "viewportScrollDown",     1));
    JS_SetPropertyStr(c, global, "viewportPageUp",         JS_NewCFunction(c, _js_viewport_page_up,         "viewportPageUp",         1));
    JS_SetPropertyStr(c, global, "viewportPageDown",       JS_NewCFunction(c, _js_viewport_page_down,       "viewportPageDown",       1));
    /* fs module backing functions */
    JS_SetPropertyStr(c, global, "__fs_read_text",  JS_NewCFunction(c, _js_fs_read_text,  "__fs_read_text",  1));
    JS_SetPropertyStr(c, global, "__fs_write_text", JS_NewCFunction(c, _js_fs_write_text, "__fs_write_text", 2));
    JS_SetPropertyStr(c, global, "__fs_write_bytes",JS_NewCFunction(c, _js_fs_write_bytes,"__fs_write_bytes",2));
    JS_SetPropertyStr(c, global, "__fs_exists",     JS_NewCFunction(c, _js_fs_exists,     "__fs_exists",     1));
    JS_SetPropertyStr(c, global, "__fs_size",       JS_NewCFunction(c, _js_fs_size,       "__fs_size",       1));
    JS_SetPropertyStr(c, global, "__fs_is_file",    JS_NewCFunction(c, _js_fs_is_file,    "__fs_is_file",    1));
    JS_SetPropertyStr(c, global, "__fs_is_dir",     JS_NewCFunction(c, _js_fs_is_dir,     "__fs_is_dir",     1));
    JS_SetPropertyStr(c, global, "__fs_read_bytes", JS_NewCFunction(c, _js_fs_read_bytes, "__fs_read_bytes", 1));
    JS_SetPropertyStr(c, global, "__fs_mkdir",      JS_NewCFunction(c, _js_fs_mkdir,      "__fs_mkdir",      2));
    JS_SetPropertyStr(c, global, "__fs_unlink",     JS_NewCFunction(c, _js_fs_unlink,     "__fs_unlink",     1));
    JS_SetPropertyStr(c, global, "__fs_read_dir",   JS_NewCFunction(c, _js_fs_read_dir,   "__fs_read_dir",   1));
    JS_SetPropertyStr(c, global, "__fs_copy_file",  JS_NewCFunction(c, _js_fs_copy_file,  "__fs_copy_file",  2));
    JS_SetPropertyStr(c, global, "__fs_stat",       JS_NewCFunction(c, _js_fs_stat,       "__fs_stat",       1));
    JS_FreeValue(c, global);
}
