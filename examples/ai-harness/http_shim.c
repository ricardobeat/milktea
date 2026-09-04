#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>

struct resp { int status; char* body; int len; };

void mimo_global_init(void) {
    // Intentionally empty: libcurl initializes itself per-thread on first
    // easy use, and calling curl_global_init from a worker thread is unsafe
    // (taro.c calls it once on the main thread for the same reason).
}

// raw_cb receives every response byte as it arrives. Return 0 to keep
// reading, non-zero to abort the transfer.
typedef int (*raw_cb)(const char* data, int len, void* user);

typedef struct { char* buf; size_t len; size_t cap; } buf_t;

static void buf_append(buf_t* b, const char* ptr, size_t n) {
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

typedef struct {
    raw_cb cb;
    void* user;
    int aborted;
} raw_ctx_t;

// Forward raw bytes straight to the C3 callback. No buffering or parsing
// here: the payload pointer belongs to libcurl and is only valid for the
// duration of this call, so the C3 side must copy anything it keeps.
static size_t write_raw(char* ptr, size_t size, size_t nmemb, void* ud) {
    size_t n = size * nmemb;
    raw_ctx_t* r = (raw_ctx_t*)ud;
    if (r->cb(ptr, (int)n, r->user) != 0) {
        r->aborted = 1;
        return 0;
    }
    return n;
}

static void setup_common(CURL* curl, const char* url, const char* auth,
                         const char* body, long timeout_s,
                         struct curl_slist** hdrs_out) {
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body ? body : "");
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, body ? (long)strlen(body) : 0L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_s);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

    char auth_hdr[1024];
    snprintf(auth_hdr, sizeof(auth_hdr), "Authorization: Bearer %s", auth ? auth : "");
    struct curl_slist* hdrs = NULL;
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");
    hdrs = curl_slist_append(hdrs, auth_hdr);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    *hdrs_out = hdrs;
}

static size_t write_batch(char* ptr, size_t size, size_t nmemb, void* ud) {
    size_t n = size * nmemb;
    buf_append((buf_t*)ud, ptr, n);
    return n;
}

int mimo_http_post(const char* url, const char* auth, const char* body,
                   int timeout_ms, struct resp* r) {
    if (!r) return 0;
    r->body = NULL;
    r->len = 0;
    r->status = -1;

    long secs = timeout_ms / 1000;
    if (secs < 1) secs = 1;

    CURL* curl = curl_easy_init();
    if (!curl) return 0;

    struct curl_slist* hdrs = NULL;
    setup_common(curl, url, auth, body, secs, &hdrs);

    buf_t out = {0};
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_batch);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &out);

    CURLcode res = curl_easy_perform(curl);
    long code = 0;
    if (res == CURLE_OK) curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);

    curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) { free(out.buf); return 0; }
    r->status = (int)code;
    r->body = out.buf;
    r->len = (int)out.len;
    return 1;
}

// mimo_http_post_stream calls `cb` with raw response bytes as they arrive and
// writes the final HTTP status into *out_status. SSE parsing happens on the
// C3 side. Returns 1 on success (or caller-aborted transfer), 0 on failure.
int mimo_http_post_stream(const char* url, const char* auth, const char* body,
                          int timeout_ms, raw_cb cb, void* user,
                          int* out_status) {
    if (!cb || !out_status) return 0;
    *out_status = -1;

    long secs = timeout_ms / 1000;
    if (secs < 1) secs = 1;

    CURL* curl = curl_easy_init();
    if (!curl) return 0;

    struct curl_slist* hdrs = NULL;
    setup_common(curl, url, auth, body, secs, &hdrs);

    raw_ctx_t r = { .cb = cb, .user = user };
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_raw);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &r);

    CURLcode res = curl_easy_perform(curl);
    long code = 0;
    if (res == CURLE_OK || r.aborted) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
        *out_status = (int)code;
    }

    curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);
    return (res == CURLE_OK || r.aborted) ? 1 : 0;
}

void mimo_free(void* p) {
    if (p) free(p);
}

// mimo_run_command runs `cmd` via /bin/sh popen, captures up to outsize-1 bytes
// of stdout into outbuf (null-terminated) and stores the exit status in
// *exit_code. Returns 1 on success, 0 if popen failed.
int mimo_run_command(const char* cmd, char* outbuf, int outsize, int* exit_code) {
    if (!outbuf || outsize <= 0) return 0;
    outbuf[0] = 0;
    *exit_code = -1;
    FILE* f = popen(cmd, "r");
    if (!f) return 0;
    size_t written = 0;
    while (written < (size_t)outsize - 1) {
        size_t n = fread(outbuf + written, 1, (size_t)(outsize - 1 - (int)written), f);
        if (n <= 0) break;
        written += n;
    }
    outbuf[written] = 0;
    *exit_code = pclose(f);
    return 1;
}
