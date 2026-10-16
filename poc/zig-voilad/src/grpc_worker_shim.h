#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VoiladRunRequest {
    const char *image;
    const char **args;
    size_t args_len;
    int64_t memory_limit_bytes;
    int32_t cpu_quota_percent;
    int attach_stdin;
} VoiladRunRequest;

typedef struct VoiladRunCallbacks {
    void *ctx;
    int (*on_context_id)(void *ctx, const char *id);
    int (*on_stdout)(void *ctx, const uint8_t *data, size_t len);
    int (*on_stderr)(void *ctx, const uint8_t *data, size_t len);
    int (*on_exit)(void *ctx, int32_t exit_code);
} VoiladRunCallbacks;

// Blocks until SIGINT/SIGTERM or server error. Returns 0 on clean shutdown.
int voilad_grpc_serve_unix(const char *socket_path, const char *voila_root,
                           int (*handle_run)(const VoiladRunRequest *req, VoiladRunCallbacks *cb));

#ifdef __cplusplus
}
#endif
