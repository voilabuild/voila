#include "grpc_worker_shim.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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
static int (*g_handle_run)(const VoiladRunRequest *, VoiladRunCallbacks *);
static int (*g_handle_set_registry)(const char *registry_url, const char *token);

typedef struct RunStreamCtx {
    grpc_call *call;
    grpc_completion_queue *cq;
    int client_gone;
} RunStreamCtx;

static uintptr_t g_op_tag = 2000;

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
    void *tag = (void *)(++g_op_tag);
    grpc_call_error err = grpc_call_start_batch(call, ops, nops, tag, NULL);
    if (err != GRPC_CALL_OK) {
        return 0;
    }
    return wait_tag(cq, tag);
}

static int send_initial_metadata(RunStreamCtx *ctx) {
    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_SEND_INITIAL_METADATA;
    op.data.send_initial_metadata.count = 0;
    op.data.send_initial_metadata.metadata = NULL;
    return run_batch(ctx->call, ctx->cq, &op, 1);
}

static Voila__V1__RunInput *recv_run_input(grpc_call *call, grpc_completion_queue *cq) {
    grpc_byte_buffer *bb = NULL;
    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_RECV_MESSAGE;
    op.data.recv_message.recv_message = &bb;
    if (!run_batch(call, cq, &op, 1)) {
        return NULL;
    }
    if (!bb) {
        return NULL;
    }

    grpc_byte_buffer_reader reader;
    grpc_byte_buffer_reader_init(&reader, bb);
    grpc_slice slice = grpc_byte_buffer_reader_readall(&reader);
    grpc_byte_buffer_reader_destroy(&reader);
    grpc_byte_buffer_destroy(bb);

    Voila__V1__RunInput *in = voila__v1__run_input__unpack(
        NULL, GRPC_SLICE_LENGTH(slice), (const uint8_t *)GRPC_SLICE_START_PTR(slice));
    grpc_slice_unref(slice);
    return in;
}

static int send_run_output(RunStreamCtx *ctx, Voila__V1__RunOutput *out) {
    size_t len = voila__v1__run_output__get_packed_size(out);
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) {
        return -1;
    }
    voila__v1__run_output__pack(out, buf);
    grpc_slice slice = grpc_slice_from_copied_buffer((const char *)buf, len);
    free(buf);
    grpc_byte_buffer *bb = grpc_raw_byte_buffer_create(&slice, 1);
    grpc_slice_unref(slice);
    if (!bb) {
        return -1;
    }

    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_SEND_MESSAGE;
    op.data.send_message.send_message = bb;
    int ok = run_batch(ctx->call, ctx->cq, &op, 1);
    grpc_byte_buffer_destroy(bb);
    return ok ? 0 : -1;
}

static int on_context_id(void *vctx, const char *id) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_CONTEXT_ID;
    out.context_id = (char *)id;
    if (send_run_output(ctx, &out) != 0) {
        ctx->client_gone = 1;
        return -1;
    }
    return 0;
}

static int on_stdout(void *vctx, const uint8_t *data, size_t len) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_STDOUT;
    out.stdout.data = (uint8_t *)data;
    out.stdout.len = len;
    if (send_run_output(ctx, &out) != 0) {
        ctx->client_gone = 1;
        return -1;
    }
    return 0;
}

static int on_stderr(void *vctx, const uint8_t *data, size_t len) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_STDERR;
    out.stderr.data = (uint8_t *)data;
    out.stderr.len = len;
    if (send_run_output(ctx, &out) != 0) {
        ctx->client_gone = 1;
        return -1;
    }
    return 0;
}

static int on_stats(void *vctx, uint64_t chunks_fetched, uint64_t bytes_fetched, uint64_t image_chunks,
                    uint64_t image_bytes) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_STATS;
    Voila__V1__FetchStats st = VOILA__V1__FETCH_STATS__INIT;
    st.chunks_fetched = chunks_fetched;
    st.bytes_fetched = bytes_fetched;
    st.image_chunks = image_chunks;
    st.image_bytes = image_bytes;
    out.stats = &st;
    if (send_run_output(ctx, &out) != 0) {
        ctx->client_gone = 1;
        return -1;
    }
    return 0;
}

static int on_exit(void *vctx, int32_t code) {
    RunStreamCtx *ctx = (RunStreamCtx *)vctx;
    Voila__V1__RunOutput out = VOILA__V1__RUN_OUTPUT__INIT;
    out.output_case = VOILA__V1__RUN_OUTPUT__OUTPUT_EXIT_CODE;
    out.exit_code = code;
    if (send_run_output(ctx, &out) != 0) {
        ctx->client_gone = 1;
        return -1;
    }
    return 0;
}

static void drain_client_input(grpc_call *call, grpc_completion_queue *cq) {
    for (;;) {
        Voila__V1__RunInput *in = recv_run_input(call, cq);
        if (!in) {
            break;
        }
        voila__v1__run_input__free_unpacked(in, NULL);
    }
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

static void handle_run_call(grpc_call *call, grpc_completion_queue *cq) {
    RunStreamCtx stream = {.call = call, .cq = cq, .client_gone = 0};

    if (!send_initial_metadata(&stream)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }

    Voila__V1__RunInput *first = recv_run_input(call, cq);
    if (!first || first->input_case != VOILA__V1__RUN_INPUT__INPUT_SPEC || !first->spec) {
        if (first) {
            voila__v1__run_input__free_unpacked(first, NULL);
        }
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
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

    int rc = g_handle_run(&req, &cb);
    voila__v1__run_input__free_unpacked(first, NULL);

    // Stdin streaming is not wired; drain any client follow-up frames before close.
    drain_client_input(call, cq);

    grpc_status_code st = GRPC_STATUS_OK;
    if (rc != 0) {
        st = GRPC_STATUS_ABORTED;
    }
    finish_call(call, cq, st);
}

static Voila__V1__SetRegistryRequest *recv_set_registry_input(grpc_call *call, grpc_completion_queue *cq) {
    grpc_byte_buffer *bb = NULL;
    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_RECV_MESSAGE;
    op.data.recv_message.recv_message = &bb;
    if (!run_batch(call, cq, &op, 1)) {
        return NULL;
    }
    if (!bb) {
        return NULL;
    }

    grpc_byte_buffer_reader reader;
    grpc_byte_buffer_reader_init(&reader, bb);
    grpc_slice slice = grpc_byte_buffer_reader_readall(&reader);
    grpc_byte_buffer_reader_destroy(&reader);
    grpc_byte_buffer_destroy(bb);

    Voila__V1__SetRegistryRequest *in = voila__v1__set_registry_request__unpack(
        NULL, GRPC_SLICE_LENGTH(slice), (const uint8_t *)GRPC_SLICE_START_PTR(slice));
    grpc_slice_unref(slice);
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
    grpc_slice slice = grpc_slice_from_copied_buffer((const char *)buf, len);
    free(buf);
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

static void handle_set_registry_call(grpc_call *call, grpc_completion_queue *cq) {
    grpc_op op;
    memset(&op, 0, sizeof(op));
    op.op = GRPC_OP_SEND_INITIAL_METADATA;
    op.data.send_initial_metadata.count = 0;
    op.data.send_initial_metadata.metadata = NULL;
    if (!run_batch(call, cq, &op, 1)) {
        finish_call(call, cq, GRPC_STATUS_INTERNAL);
        return;
    }

    Voila__V1__SetRegistryRequest *req = recv_set_registry_input(call, cq);
    if (!req) {
        finish_call(call, cq, GRPC_STATUS_INVALID_ARGUMENT);
        return;
    }

    grpc_status_code st = GRPC_STATUS_OK;
    if (!g_handle_set_registry) {
        st = GRPC_STATUS_UNIMPLEMENTED;
    } else {
        const char *url = req->registry_url ? req->registry_url : "";
        const char *token = req->token ? req->token : "";
        if (g_handle_set_registry(url, token) != 0) {
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

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

int voilad_grpc_serve_unix(const char *socket_path, const char *voila_root,
                           int (*handle_run)(const VoiladRunRequest *, VoiladRunCallbacks *),
                           int (*handle_set_registry)(const char *registry_url, const char *token)) {
    if (!socket_path || !voila_root || !handle_run) {
        return 1;
    }
    g_handle_run = handle_run;
    g_handle_set_registry = handle_set_registry;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    grpc_init();

    grpc_server *server = grpc_server_create(NULL, NULL);
    if (!server) {
        grpc_shutdown();
        return 2;
    }

    grpc_completion_queue *cq_notify = grpc_completion_queue_create_for_next(NULL);
    grpc_completion_queue *cq_call = grpc_completion_queue_create_for_next(NULL);
    grpc_server_register_completion_queue(server, cq_notify, NULL);

    grpc_server_credentials *creds = grpc_insecure_server_credentials_create();
    char addr[512];
    snprintf(addr, sizeof(addr), "unix://%s", socket_path);
    if (grpc_server_add_http2_port(server, addr, creds) <= 0) {
        grpc_server_credentials_release(creds);
        grpc_completion_queue_destroy(cq_call);
        grpc_completion_queue_destroy(cq_notify);
        grpc_server_destroy(server);
        grpc_shutdown();
        return 2;
    }
    grpc_server_credentials_release(creds);

    grpc_server_start(server);
    chmod(socket_path, 0666);

    const void *tag_request = (const void *)1;

    while (!g_stop) {
        grpc_call *call = NULL;
        grpc_call_details details;
        grpc_call_details_init(&details);
        grpc_metadata_array metadata;
        grpc_metadata_array_init(&metadata);

        grpc_call_error req_err = grpc_server_request_call(
            server, &call, &details, &metadata, cq_call, cq_notify, (void *)tag_request);
        if (req_err != GRPC_CALL_OK) {
            grpc_call_details_destroy(&details);
            grpc_metadata_array_destroy(&metadata);
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
            if (ev.type == GRPC_OP_COMPLETE && ev.tag == tag_request) {
                accepted = 1;
                if (ev.success && call) {
                    const char *method = grpc_slice_to_c_string(details.method);
                    if (method && strcmp(method, "/voila.v1.Worker/Run") == 0) {
                        handle_run_call(call, cq_call);
                    } else if (method && strcmp(method, "/voila.v1.Worker/SetRegistry") == 0) {
                        handle_set_registry_call(call, cq_call);
                    } else {
                        finish_call(call, cq_call, GRPC_STATUS_UNIMPLEMENTED);
                    }
                    gpr_free((void *)method);
                    grpc_call_unref(call);
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
        grpc_event ev = grpc_completion_queue_next(cq_notify, gpr_inf_future(GPR_CLOCK_REALTIME),
                                                   NULL);
        if (ev.type == GRPC_QUEUE_SHUTDOWN) {
            break;
        }
    }

    grpc_completion_queue_destroy(cq_call);
    grpc_completion_queue_destroy(cq_notify);
    grpc_server_destroy(server);
    grpc_shutdown();
    return 0;
}
