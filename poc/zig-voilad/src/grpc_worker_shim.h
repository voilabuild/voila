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
    int (*on_stats)(void *ctx, uint64_t chunks_fetched, uint64_t bytes_fetched, uint64_t image_chunks,
                    uint64_t image_bytes);
    int (*on_exit)(void *ctx, int32_t exit_code);
} VoiladRunCallbacks;

typedef struct VoiladExecCallbacks {
    void *ctx;
    int (*on_stdout)(void *ctx, const uint8_t *data, size_t len);
    int (*on_stderr)(void *ctx, const uint8_t *data, size_t len);
    int (*on_exit)(void *ctx, int32_t exit_code);
} VoiladExecCallbacks;

typedef struct VoiladWorkerHooks {
    int (*handle_run)(const VoiladRunRequest *req, VoiladRunCallbacks *cb);
    int (*handle_exec)(const char *ctx_id, const char **args, size_t args_len, VoiladExecCallbacks *cb);
    int (*handle_set_registry)(const char *registry_url, const char *token);
} VoiladWorkerHooks;

typedef struct VoiladContextInfo {
    const char *id;
    const char *image_ref;
    const char *status;
    int64_t started_ns;
    int32_t pid;
    int32_t exit_code;
} VoiladContextInfo;

typedef struct VoiladLogChunk {
    const uint8_t *data;
    size_t len;
    int stderr;
    int64_t timestamp_ns;
} VoiladLogChunk;

typedef struct VoiladEvent {
    const char *context_id;
    int32_t type;
    int64_t timestamp_ns;
    int32_t exit_code;
} VoiladEvent;

void voilad_list_visit(void (*add_fn)(void *ctx, const VoiladContextInfo *info), void *ctx);
int voilad_kill(const char *ctx_id, int32_t signal);
int voilad_logs_replay(const char *ctx_id, int (*chunk_fn)(void *ctx, const VoiladLogChunk *chunk), void *ctx);
void voilad_logs_follow(const char *ctx_id, int (*chunk_fn)(void *ctx, const VoiladLogChunk *chunk), void *ctx,
                        volatile int *stop);
void voilad_events_stream(const char *filter_ctx, int (*event_fn)(void *ctx, const VoiladEvent *ev), void *ctx,
                          volatile int *stop);

int voilad_grpc_serve_unix(const char *socket_path, const char *voila_root, const VoiladWorkerHooks *hooks);

#ifdef __cplusplus
}
#endif
