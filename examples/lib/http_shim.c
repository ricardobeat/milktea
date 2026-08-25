#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Aimed at the macOS system libcurl which crashes inside its TLS backend
// (Curl_ssl_multi) when driven from a non-main thread / after a fork. To avoid
// that entirely we shell out to the curl command-line tool in a child process,
// so any TLS failure is isolated to the child and cannot take the app down.

struct resp { int status; char* body; int len; };

void mimo_global_init(void) {
    // no-op now that we don't use in-process libcurl
}

static void append_file_to_resp(struct resp* r, const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return;
    long sz = 0;
    if (fseek(f, 0, SEEK_END) == 0 && (sz = ftell(f)) >= 0 && fseek(f, 0, SEEK_SET) == 0) {
        if (sz > 8 * 1024 * 1024) sz = 8 * 1024 * 1024;
        char* nb = (char*)malloc((size_t)sz + 1);
        if (nb) {
            size_t got = fread(nb, 1, (size_t)sz, f);
            nb[got] = 0;
            r->body = nb;
            r->len = (int)got;
        }
    }
    fclose(f);
}

int mimo_http_post(const char* url, const char* auth, const char* body,
                   int timeout_ms, struct resp* r) {
    if (!r) return 0;
    r->body = NULL;
    r->len = 0;
    r->status = -1;

    char reqfile[] = "/tmp/mimo_req_XXXXXX";
    char resfile[] = "/tmp/mimo_res_XXXXXX";
    int rfd = mkstemp(reqfile);
    int sfd = mkstemp(resfile);
    if (rfd < 0 || sfd < 0) {
        if (rfd >= 0) { close(rfd); unlink(reqfile); }
        if (sfd >= 0) { close(sfd); unlink(resfile); }
        return 0;
    }
    if (body) (void)write(rfd, body, strlen(body));
    close(rfd);

    int secs = timeout_ms / 1000;
    if (secs < 1) secs = 1;

    char cmd[16384];
    snprintf(cmd, sizeof(cmd),
        "curl -sS --max-time %d "
        "-H 'Content-Type: application/json' "
        "-H 'Authorization: Bearer %s' "
        "--data-binary @%s -o %s -w '%%{http_code}' '%s' 2>/dev/null",
        secs, auth, reqfile, resfile, url);

    int got_status = 0;
    FILE* f = popen(cmd, "r");
    if (f) {
        char statbuf[64] = {0};
        if (fgets(statbuf, (int)sizeof(statbuf), f)) {
            r->status = atoi(statbuf);
            got_status = 1;
        }
        pclose(f);
    }

    append_file_to_resp(r, resfile);
    unlink(reqfile);
    unlink(resfile);
    return got_status;
}

// stream_cb is called for each SSE "data:" line.  chunk/len is the JSON payload
// (without the "data: " prefix).  Return 0 to keep reading, non-zero to abort.
typedef int (*stream_cb)(const char* chunk, int len, void* user);

// mimo_http_post_stream opens a streaming SSE connection.  It calls `cb` for
// each data chunk and writes the final HTTP status into *out_status.
// Returns 1 on success (connection opened), 0 on failure.
int mimo_http_post_stream(const char* url, const char* auth, const char* body,
                          int timeout_ms, stream_cb cb, void* user,
                          int* out_status) {
    if (!cb || !out_status) return 0;
    *out_status = -1;

    char reqfile[] = "/tmp/mimo_req_XXXXXX";
    int rfd = mkstemp(reqfile);
    if (rfd < 0) return 0;
    if (body) (void)write(rfd, body, strlen(body));
    close(rfd);

    int secs = timeout_ms / 1000;
    if (secs < 1) secs = 1;

    // -N disables output buffering so we get lines as they arrive.
    // -w appends a status marker after the stream finishes.
    char cmd[16384];
    snprintf(cmd, sizeof(cmd),
        "curl -sS -N --max-time %d "
        "-H 'Content-Type: application/json' "
        "-H 'Authorization: Bearer %s' "
        "--data-binary @%s "
        "-w '\\n__STATUS__%%{http_code}__\\n' "
        "'%s' 2>/dev/null",
        secs, auth, reqfile, url);

    FILE* f = popen(cmd, "r");
    if (!f) { unlink(reqfile); return 0; }

    char line[65536];
    int got_status = 0;
    while (fgets(line, sizeof(line), f)) {
        // Strip trailing newline.
        int slen = (int)strlen(line);
        while (slen > 0 && (line[slen-1] == '\n' || line[slen-1] == '\r')) slen--;
        line[slen] = 0;

        // Check for the status marker we appended with -w.
        if (slen > 12 && memcmp(line, "__STATUS__", 10) == 0 &&
            line[slen-2] == '_' && line[slen-1] == '_') {
            char tmp[16] = {0};
            int digits = slen - 12;
            if (digits > 0 && digits < (int)sizeof(tmp)) {
                memcpy(tmp, line + 10, (size_t)digits);
                *out_status = atoi(tmp);
                got_status = 1;
            }
            continue;
        }

        // SSE data lines start with "data: ".
        if (slen > 6 && memcmp(line, "data: ", 6) == 0) {
            const char* payload = line + 6;
            int plen = slen - 6;
            // Skip the [DONE] sentinel.
            if (plen == 5 && memcmp(payload, "[DONE]", 5) == 0) continue;
            if (cb(payload, plen, user) != 0) break;
        }
    }
    pclose(f);
    unlink(reqfile);
    return got_status;
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