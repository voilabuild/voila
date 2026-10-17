#include "grpc_worker_shim.h"

#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>

#include <grpc/byte_buffer.h>
#include <grpc/impl/codegen/byte_buffer_reader.h>
#include <grpc/grpc.h>
#include <grpc/grpc_security.h>
#include <grpc/slice.h>
#include <grpc/status.h>
#include <grpc/support/alloc.h>
#include <grpc/support/time.h>

#include "worker_run.pb-c.h"

static volatile sig_atomic_t g_stop;
static const VoiladWorkerHooks *g_hooks;

typedef struct RunStreamCtx {
    grpc_call *call;
    grpc_completion_queue *cq;
    int client_gone;
} RunStreamCtx;

typedef struct ExecStreamCtx {
    grpc_call *call;
    grpc_completion_queue *cq;
    int client_gone;
} ExecStreamCtx;

typedef struct ListBuildCtx {
    Voila__V1__ListResponse *resp;
    size_t cap;
} ListBuildCtx;

static _Atomic uintptr_t g_op_tag = 2000;

static char *dupstr(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static int wait_tag(grpc_completion_queue *cq, void *tag) {
    for (;;) {
        grpc_event ev =
            grpc_completion_queue_next(cq, gpr_inf_future(GPR_CLOCK_REALTIME), NULL);
        if (ev.type == GRPC_OP_COMPLETE && ev.tag == tag) {
            return ev.success;
        }
    }
}

static int run_batch(grpc_call *call, grpc_completion_queue *cq, grpc_op *ops, size_t nops) {
    void *tag = (void *)(atomic_fetch_add(&g_op_tag, 1) + 1);
    grpc_call_error err = grpc_call_start_batch(call, ops, nops, tag, NULL);
    if (err != GRPC_CALL_OK) {
        return 0;
    }
    return wait_tag(cq, tag);
}

static int send_initial_metadata(grpc_call *call, grpc_completion_queue *cq) {
    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_SEND_INITIAL_METADATA;
    op.data.send_initial_metadata.count = 0;
    op.data.send_initial_metadata.metadata = NULL;
    return run_batch(call, cq, &op, 1);
}

typedef struct {
    grpc_slice slice;
    int ok;
} RecvMsg;

static RecvMsg recv_message(grpc_call *call, grpc_completion_queue *cq) {
    RecvMsg out = {.slice = grpc_empty_slice(), .ok = 0};
    grpc_byte_buffer *bb = NULL;
    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_RECV_MESSAGE;
    op.data.recv_message.recv_message = &bb;
    if (!run_batch(call, cq, &op, 1)) {
        return out;
    }
    if (!bb) {
        return out;
    }
    grpc_byte_buffer_reader reader;
    grpc_byte_buffer_reader_init(&reader, bb);
    out.slice = grpc_byte_buffer_reader_readall(&reader);
    out.ok = 1;
    grpc_byte_buffer_reader_destroy(&reader);
    grpc_byte_buffer_destroy(bb);
    return out;
}

static void free_recv(RecvMsg *m) {
    if (m->ok) {
        grpc_slice_unref(m->slice);
        m->ok = 0;
    }
}

static int send_bytes(grpc_call *call, grpc_completion_queue *cq, const uint8_t *buf, size_t len) {
    grpc_slice slice = grpc_slice_from_copied_buffer((const char *)buf, len);
    grpc_byte_buffer *bb = grpc_raw_byte_buffer_create(&slice, 1);
    grpc_slice_unref(slice);
    if (!bb) {
        return -1;
    }
    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_SEND_MESSAGE;
    op.data.send_message.send_message = bb;
    int ok = run_batch(call, cq, &op, 1);
    grpc_byte_buffer_destroy(bb);
    return ok ? 0 : -1;
}

static int finish_call(grpc_call *call, grpc_completion_queue *cq, grpc_status_code code) {
    int cancelled = 0;
    grpc_op ops[2];
    memset(ops, 0, sizeof(ops));
    ops[0].op = GRPC_OP_RECV_CLOSE_ON_SERVER;
    ops[0].data.recv_close_on_server.cancelled = &cancelled;
    ops[1].op = GRPC_OP_SEND_STATUS_FROM_SERVER;
    ops[1].data.send_status_from_server.status = code;
    ops[1].data.send_status_from_server.trailing_metadata = NULL;
    ops[1].data.send_status_from_server.trailing_metadata_count = 0;
    ops[1].data.send_status_from_server.status_details = NULL;
    return run_batch(call, cq, ops, 2) ? 0 : -1;
}

static int send_run_output(RunStreamCtx *ctx, Voila__V1__RunOutput *out) {
    size_t len = voila__v1__run_output__get_packed_size(out);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) {
        return -1;
    }
    voila__v1__run_output__pack(out, buf);
    int rc = send_bytes(ctx->call, ctx->cq, buf, len);
    free(buf);
    if (rc != 0) {
        ctx->client_gone = 1;
    }
    return rc;
}

static int on_context_id(void *vctx, const char *id) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_CONTEXT_ID;
    out.context_id = (char *)id;
    return send_run_output(ctx, &out);
}

static int on_stdout(void *vctx, const uint8_t *data, size_t len) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_STDOUT;
    out.stdout.data = (uint8_t *)data;
    out.stdout.len = len;
    return send_run_output(ctx, &out);
}

static int on_stderr(void *vctx, const uint8_t *data, size_t len) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_STDERR;
    out.stderr.data = (uint8_t *)data;
    out.stderr.len = len;
    return send_run_output(ctx, &out);
}

static int on_exit(void *vctx, int32_t code) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_EXIT_CODE;
    out.exit_code = code;
    return send_run_output(ctx, &out);
}

static int on_stats(void *vctx, uint64_t chunks_fetched, uint64_t bytes_fetched, uint64_t image_chunks,
                    uint64_t image_bytes) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__FetchStats stats = VOILA__V1__FETCH_STATS__INIT;
    stats.chunks_fetched = chunks_fetched;
    stats.bytes_fetched = bytes_fetched;
    stats.image_chunks = image_chunks;
    stats.image_bytes = image_bytes;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_STATS;
    out.stats = &stats;
    return send_run_output(ctx, &out);
}

static void drain_run_input(grpc_call *call, grpc_completion_queue *cq) {
    for (;;) {
        RecvMsg rm = recv_message(call, cq);
        if (!rm.ok || !GRPC_SLICE_LENGTH(rm.slice)) {
            free_recv(&rm);
            break;
        }
        Voila__V1__RunInput *in = voila__v1__run_input__unpack(
            NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
        free_recv(&rm);
        if (!in) {
            break;
        }
        voila__v1__run_input__free_unpacked(in, NULL);
    }
}

static void handle_run_call(grpc_call *call, grpc_completion_queue *cq) {
    RunStreamCtx stream = {.call = call, .cq = cq, .client_gone = 0};
    if (!send_initial_metadata(call, cq)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }
    RecvMsg rm = recv_message(call, cq);
    Voila__V1__RunInput *first = voila__v1__run_input__unpack(
        NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
    free_recv(&rm);
    if (!first || first->input_case != VOILA__V1__RUN_INPUT__INPUT_SPEC || !first->spec) {
        if (first) {
            voila__v1__run_input__free_unpacked(first, NULL);
        }
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
        return;
    }
    if (!g_hooks || !g_hooks->handle_run) {
        voila__v1__run_input__free_unpacked(first, NULL);
        finish_call(call, cq, GRPC_STATUS_UNIMPLEMENTED);
        return;
    }
    Voila__V1__RunSpec *spec = first->spec;
    VoiladRunCallbacks cb = {
        .ctx = &stream,
        .on_context_id = on_context_id,
        .on_stdout = on_stdout,
        .on_stderr = on_stderr,
        .on_stats = on_stats,
        .on_exit = on_exit,
    };
    VoiladRunRequest req = {
        .image = spec->image,
        .args = spec->n_args ? (const char **)spec->args : NULL,
        .args_len = spec->n_args,
        .memory_limit_bytes = spec->memory_limit_bytes,
        .cpu_quota_percent = spec->cpu_quota_percent,
        .attach_stdin = spec->attach_stdin ? 1 : 0,
    };
    int rc = g_hooks->handle_run(&req, &cb);
    voila__v1__run_input__free_unpacked(first, NULL);
    drain_run_input(call, cq);
    finish_call(call, cq, rc != 0 ? GRPC_STATUS_ABORTED : GRPC_STATUS_OK);
}

static int send_exec_output(ExecStreamCtx *ctx, Voila__V1__ExecOutput *out) {
    size_t len = voila__v1__exec_output__get_packed_size(out);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) {
        return -1;
    }
    voila__v1__exec_output__pack(out, buf);
    int rc = send_bytes(ctx->call, ctx->cq, buf, len);
    free(buf);
    if (rc != 0) {
        ctx->client_gone = 1;
    }
    return rc;
}

static int exec_on_stdout(void *vctx, const uint8_t *data, size_t len) {
    ExecStreamCtx *ctx = (ExecStreamCtx *)vctx;
    Voila__V1__ExecOutput out = VOILA__V1__EXEC_OUTPUT__INIT;
    out.output_case = VOILA__V1__EXEC_OUTPUT__OUTPUT_STDOUT;
    out.stdout.data = (uint8_t *)data;
    out.stdout.len = len;
    return send_exec_output(ctx, &out);
}

static int exec_on_stderr(void *vctx, const uint8_t *data, size_t len) {
    ExecStreamCtx *ctx = (ExecStreamCtx *)vctx;
    Voila__V1__ExecOutput out = VOILA__V1__EXEC_OUTPUT__INIT;
    out.output_case = VOILA__V1__EXEC_OUTPUT__OUTPUT_STDERR;
    out.stderr.data = (uint8_t *)data;
    out.stderr.len = len;
    return send_exec_output(ctx, &out);
}

static void handle_exec_call(grpc_call *call, grpc_completion_queue *cq) {
    ExecStreamCtx stream = {.call = call, .cq = cq, .client_gone = 0};
    if (!send_initial_metadata(call, cq)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }
    RecvMsg rm = recv_message(call, cq);
    Voila__V1__ExecInput *first = voila__v1__exec_input__unpack(
        NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
    free_recv(&rm);
    if (!first || first->input_case != VOILA__V1__EXEC_INPUT__INPUT_SPEC || !first->spec) {
        if (first) {
            voila__v1__exec_input__free_unpacked(first, NULL);
        }
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
        return;
    }
    Voila__V1__ExecSpec *spec = first->spec;
    if (!spec->context_id || !spec->n_args) {
        voila__v1__exec_input__free_unpacked(first, NULL);
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
        return;
    }
    if (!g_hooks || !g_hooks->handle_exec) {
        voila__v1__exec_input__free_unpacked(first, NULL);
        finish_call(call, cq, GRPC_STATUS_UNIMPLEMENTED);
        return;
    }
    VoiladExecCallbacks cb = {
        .ctx = &stream,
        .on_stdout = exec_on_stdout,
        .on_stderr = exec_on_stderr,
        .on_exit = NULL,
    };
    int code = g_hooks->handle_exec(spec->context_id, (const char **)spec->args, spec->n_args, &cb);
    voila__v1__exec_input__free_unpacked(first, NULL);
    Voila__V1__ExecOutput out = VOILA__V1__EXEC_OUTPUT__INIT;
    out.output_case = VOILA__V1__EXEC_OUTPUT__OUTPUT_EXIT_CODE;
    out.exit_code = code;
    send_exec_output(&stream, &out);
    finish_call(call, cq, code < 0 ? GRPC_STATUS_ABORTED : GRPC_STATUS_OK);
}

static void add_list_ctx(void *vctx, const VoiladContextInfo *ci) {
    ListBuildCtx *b = (ListBuildCtx *)vctx;
    if (b->resp->n_contexts >= b->cap) {
        size_t new_cap = b->cap ? b->cap * 2 : 8;
        Voila__V1__ContextInfo **nc =
            (Voila__V1__ContextInfo **)realloc(b->resp->contexts, new_cap * sizeof(Voila__V1__ContextInfo *));
        if (!nc) {
            return;
        }
        b->resp->contexts = nc;
        b->cap = new_cap;
    }
    Voila__V1__ContextInfo *info = (Voila__V1__ContextInfo *)calloc(1, sizeof(Voila__V1__ContextInfo));
    if (!info) {
        return;
    }
    voila__v1__context_info__init(info);
    if (ci->id) info->id = dupstr(ci->id);
    if (ci->image_ref) info->image_ref = dupstr(ci->image_ref);
    if (ci->status) info->status = dupstr(ci->status);
    info->started_ns = ci->started_ns;
    info->pid = ci->pid;
    info->exit_code = ci->exit_code;
    b->resp->contexts[b->resp->n_contexts++] = info;
}

static void handle_list_call(grpc_call *call, grpc_completion_queue *cq) {
    if (!send_initial_metadata(call, cq)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }
    RecvMsg rm = recv_message(call, cq);
    if (rm.ok && GRPC_SLICE_LENGTH(rm.slice)) {
        Voila__V1__ListRequest *req = voila__v1__list_request__unpack(
            NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
        if (req) {
            voila__v1__list_request__free_unpacked(req, NULL);
        }
    }
    free_recv(&rm);

    Voila__V1__ListResponse resp = VOILA__V1__LIST_RESPONSE__INIT;
    ListBuildCtx b = {.resp = &resp, .cap = 0};
    voilad_list_visit(add_list_ctx, &b);

    size_t len = voila__v1__list_response__get_packed_size(&resp);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (buf) {
        voila__v1__list_response__pack(&resp, buf);
        send_bytes(call, cq, buf, len);
        free(buf);
    }
    for (size_t i = 0; i < resp.n_contexts; i++) {
        Voila__V1__ContextInfo *info = resp.contexts[i];
        free(info->id);
        free(info->image_ref);
        free(info->status);
        free(info);
    }
    free(resp.contexts);
    finish_call(call, cq, GRPC_STATUS_OK);
}

static void handle_kill_call(grpc_call *call, grpc_completion_queue *cq) {
    if (!send_initial_metadata(call, cq)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }
    RecvMsg rm = recv_message(call, cq);
    Voila__V1__KillRequest *req = voila__v1__kill_request__unpack(
        NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
    free_recv(&rm);
    if (!req || !req->context_id) {
        if (req) {
            voila__v1__kill_request__free_unpacked(req, NULL);
        }
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
        return;
    }
    int rc = voilad_kill(req->context_id, req->signal);
    voila__v1__kill_request__free_unpacked(req, NULL);
    grpc_status_code st = GRPC_STATUS_OK;
    if (rc == 1) {
        st = GRPC_STATUS_NOT_FOUND;
    } else if (rc == 2) {
        st = GRPC_STATUS_FAILED_PRECONDITION;
    } else if (rc == 3) {
        st = GRPC_STATUS_ABORTED;
    }
    Voila__V1__KillResponse kresp = VOILA__V1__KILL_RESPONSE__INIT;
    size_t len = voila__v1__kill_response__get_packed_size(&kresp);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (buf) {
        voila__v1__kill_response__pack(&kresp, buf);
        send_bytes(call, cq, buf, len);
        free(buf);
    }
    finish_call(call, cq, st);
}

typedef struct LogsStreamCtx {
    grpc_call *call;
    grpc_completion_queue *cq;
    volatile int stop;
} LogsStreamCtx;

static int logs_chunk_cb(void *vctx, const VoiladLogChunk *chunk) {
    LogsStreamCtx *s = (LogsStreamCtx *)vctx;
    Voila__V1__LogChunk lc = VOILA__V1__LOG_CHUNK__INIT;
    lc.data.data = (uint8_t *)chunk->data;
    lc.data.len = chunk->len;
    lc.stderr = chunk->stderr ? 1 : 0;
    lc.timestamp_ns = chunk->timestamp_ns;
    size_t len = voila__v1__log_chunk__get_packed_size(&lc);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) {
        s->stop = 1;
        return -1;
    }
    voila__v1__log_chunk__pack(&lc, buf);
    int rc = send_bytes(s->call, s->cq, buf, len);
    free(buf);
    if (rc != 0) {
        s->stop = 1;
        return -1;
    }
    return 0;
}

static void handle_logs_call(grpc_call *call, grpc_completion_queue *cq) {
    if (!send_initial_metadata(call, cq)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }
    RecvMsg rm = recv_message(call, cq);
    Voila__V1__LogsRequest *req = voila__v1__logs_request__unpack(
        NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
    free_recv(&rm);
    if (!req || !req->context_id) {
        if (req) {
            voila__v1__logs_request__free_unpacked(req, NULL);
        }
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
        return;
    }
    LogsStreamCtx sctx = {.call = call, .cq = cq, .stop = 0};
    int rc = voilad_logs_replay(req->context_id, logs_chunk_cb, &sctx);
    if (rc == 1) {
        voila__v1__logs_request__free_unpacked(req, NULL);
        finish_call(call, cq, GRPC_STATUS_NOT_FOUND);
        return;
    }
    if (req->follow && !sctx.stop) {
        voilad_logs_follow(req->context_id, logs_chunk_cb, &sctx, &sctx.stop);
    }
    voila__v1__logs_request__free_unpacked(req, NULL);
    finish_call(call, cq, GRPC_STATUS_OK);
}

typedef struct EventsStreamCtx {
    grpc_call *call;
    grpc_completion_queue *cq;
    volatile int stop;
} EventsStreamCtx;

static int events_cb(void *vctx, const VoiladEvent *ev) {
    EventsStreamCtx *s = (EventsStreamCtx *)vctx;
    Voila__V1__Event out = VOILA__V1__EVENT__INIT;
    out.context_id = (char *)ev->context_id;
    out.type = (Voila__V1__EventType)ev->type;
    out.timestamp_ns = ev->timestamp_ns;
    out.exit_code = ev->exit_code;
    size_t len = voila__v1__event__get_packed_size(&out);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) {
        s->stop = 1;
        return -1;
    }
    voila__v1__event__pack(&out, buf);
    int rc = send_bytes(s->call, s->cq, buf, len);
    free(buf);
    if (rc != 0) {
        s->stop = 1;
        return -1;
    }
    return 0;
}

static void handle_events_call(grpc_call *call, grpc_completion_queue *cq) {
    if (!send_initial_metadata(call, cq)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }
    RecvMsg rm = recv_message(call, cq);
    Voila__V1__EventsRequest *req = voila__v1__events_request__unpack(
        NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
    free_recv(&rm);
    const char *filter = "";
    if (req) {
        filter = req->context_id ? req->context_id : "";
    }
    EventsStreamCtx sctx = {.call = call, .cq = cq, .stop = 0};
    voilad_events_stream(filter, events_cb, &sctx, &sctx.stop);
    if (req) {
        voila__v1__events_request__free_unpacked(req, NULL);
    }
    finish_call(call, cq, GRPC_STATUS_OK);
}

static Voila__V1__SetRegistryRequest *recv_set_registry_input(grpc_call *call, grpc_completion_queue *cq) {
    RecvMsg rm = recv_message(call, cq);
    if (!rm.ok) {
        return NULL;
    }
    Voila__V1__SetRegistryRequest *in = voila__v1__set_registry_request__unpack(
        NULL, GRPC_SLICE_LENGTH(rm.slice), (const uint8_t *)GRPC_SLICE_START_PTR(rm.slice));
    free_recv(&rm);
    return in;
}

static int send_set_registry_output(grpc_call *call, grpc_completion_queue *cq) {
    Voila__V1__SetRegistryResponse out = VOILA__V1__SET_REGISTRY_RESPONSE__INIT;
    size_t len = voila__v1__set_registry_response__get_packed_size(&out);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) {
        return -1;
    }
    voila__v1__set_registry_response__pack(&out, buf);
    int rc = send_bytes(call, cq, buf, len);
    free(buf);
    return rc;
}

static void handle_set_registry_call(grpc_call *call, grpc_completion_queue *cq) {
    if (!send_initial_metadata(call, cq)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }
    Voila__V1__SetRegistryRequest *req = recv_set_registry_input(call, cq);
    if (!req) {
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
        return;
    }
    grpc_status_code st = GRPC_STATUS_OK;
    if (!g_hooks || !g_hooks->handle_set_registry) {
        st = GRPC_STATUS_UNIMPLEMENTED;
    } else {
        const char *url = req->registry_url ? req->registry_url : "";
        const char *token = req->token ? req->token : "";
        if (g_hooks->handle_set_registry(url, token) != 0) {
            st = GRPC_STATUS_INVALID_ARGUMENT;
        }
    }
    voila__v1__set_registry_request__free_unpacked(req, NULL);
    if (st == GRPC_STATUS_OK) {
        if (send_set_registry_output(call, cq) != 0) {
            st = GRPC_STATUS_INTERNAL;
        }
    }
    finish_call(call, cq, st);
}

typedef struct CallCtx {
    grpc_call *call;
    char *method;
    grpc_completion_queue *cq;
} CallCtx;

static void *dispatch_call(void *v) {
    CallCtx *ctx = (CallCtx *)v;
    if (!ctx->call || !ctx->method) {
        if (ctx->call) {
            finish_call(ctx->call, ctx->cq, GRPC_STATUS_UNIMPLEMENTED);
            grpc_call_unref(ctx->call);
        }
    } else if (strcmp(ctx->method, "/voila.v1.Worker/Run") == 0) {
        handle_run_call(ctx->call, ctx->cq);
        grpc_call_unref(ctx->call);
    } else if (strcmp(ctx->method, "/voila.v1.Worker/Exec") == 0) {
        handle_exec_call(ctx->call, ctx->cq);
        grpc_call_unref(ctx->call);
    } else if (strcmp(ctx->method, "/voila.v1.Worker/List") == 0) {
        handle_list_call(ctx->call, ctx->cq);
        grpc_call_unref(ctx->call);
    } else if (strcmp(ctx->method, "/voila.v1.Worker/Kill") == 0) {
        handle_kill_call(ctx->call, ctx->cq);
        grpc_call_unref(ctx->call);
    } else if (strcmp(ctx->method, "/voila.v1.Worker/Logs") == 0) {
        handle_logs_call(ctx->call, ctx->cq);
        grpc_call_unref(ctx->call);
    } else if (strcmp(ctx->method, "/voila.v1.Worker/Events") == 0) {
        handle_events_call(ctx->call, ctx->cq);
        grpc_call_unref(ctx->call);
    } else if (strcmp(ctx->method, "/voila.v1.Worker/SetRegistry") == 0) {
        handle_set_registry_call(ctx->call, ctx->cq);
        grpc_call_unref(ctx->call);
    } else {
        finish_call(ctx->call, ctx->cq, GRPC_STATUS_UNIMPLEMENTED);
        grpc_call_unref(ctx->call);
    }
    if (ctx->method) {
        gpr_free(ctx->method);
    }
    grpc_completion_queue_destroy(ctx->cq);
    free(ctx);
    return NULL;
}

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

int voilad_grpc_serve_unix(const char *socket_path, const char *voila_root, const VoiladWorkerHooks *hooks) {
    if (!socket_path || !voila_root || !hooks) {
        return 1;
    }
    g_hooks = hooks;
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    grpc_init();

    grpc_server *server = grpc_server_create(NULL, NULL);
    if (!server) {
        grpc_shutdown();
        return 2;
    }
    grpc_completion_queue *cq_notify = grpc_completion_queue_create_for_next(NULL);
    grpc_server_register_completion_queue(server, cq_notify, NULL);

    grpc_server_credentials *creds = grpc_insecure_server_credentials_create();
    char addr[512];
    snprintf(addr, sizeof(addr), "unix://%s", socket_path);
    if (grpc_server_add_http2_port(server, addr, creds) <= 0) {
        grpc_server_credentials_release(creds);
        grpc_completion_queue_destroy(cq_notify);
        grpc_server_destroy(server);
        grpc_shutdown();
        return 2;
    }
    grpc_server_credentials_release(creds);
    grpc_server_start(server);
    chmod(socket_path, 0666);

    while (!g_stop) {
        CallCtx *ctx = (CallCtx *)calloc(1, sizeof(CallCtx));
        if (!ctx) {
            break;
        }
        ctx->cq = grpc_completion_queue_create_for_next(NULL);
        if (!ctx->cq) {
            free(ctx);
            break;
        }
        grpc_call_details details;
        grpc_call_details_init(&details);
        grpc_metadata_array metadata;
        grpc_metadata_array_init(&metadata);

        grpc_call_error req_err = grpc_server_request_call(
            server, &ctx->call, &details, &metadata, ctx->cq, cq_notify, ctx);
        if (req_err != GRPC_CALL_OK) {
            grpc_call_details_destroy(&details);
            grpc_metadata_array_destroy(&metadata);
            grpc_completion_queue_destroy(ctx->cq);
            free(ctx);
            break;
        }

        int accepted = 0;
        while (!g_stop && !accepted) {
            gpr_timespec poll_deadline =
                gpr_time_add(gpr_now(GPR_CLOCK_REALTIME), gpr_time_from_millis(250, GPR_TIMESPAN));
            grpc_event ev = grpc_completion_queue_next(cq_notify, poll_deadline, NULL);
            if (ev.type == GRPC_QUEUE_TIMEOUT) {
                continue;
            }
            if (ev.type == GRPC_OP_COMPLETE && ev.tag == ctx) {
                accepted = 1;
                if (ev.success && ctx->call) {
                    ctx->method = grpc_slice_to_c_string(details.method);
                    pthread_t tid;
                    pthread_create(&tid, NULL, dispatch_call, ctx);
                    pthread_detach(tid);
                } else {
                    grpc_completion_queue_destroy(ctx->cq);
                    free(ctx);
                }
            }
        }
        grpc_call_details_destroy(&details);
        grpc_metadata_array_destroy(&metadata);
        if (g_stop) {
            break;
        }
    }

    grpc_completion_queue_shutdown(cq_notify);
    grpc_server_shutdown_and_notify(server, cq_notify, (void *)2);
    for (;;) {
        grpc_event ev = grpc_completion_queue_next(cq_notify, gpr_inf_future(GPR_CLOCK_REALTIME), NULL);
        if (ev.type == GRPC_QUEUE_SHUTDOWN) {
            break;
        }
    }
    grpc_completion_queue_destroy(cq_notify);
    grpc_server_destroy(server);
    grpc_shutdown();
    return 0;
}
