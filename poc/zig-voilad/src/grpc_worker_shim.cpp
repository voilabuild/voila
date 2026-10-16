#include "grpc_worker_shim.h"

#include <atomic>
#include <csignal>
#include <cstring>
#include <memory>
#include <string>
#include <thread>

#include <grpcpp/grpcpp.h>
#include <sys/stat.h>
#include "worker_run.grpc.pb.h"

namespace {

std::atomic<bool> g_stop{false};

void on_signal(int) { g_stop = true; }

const char *g_voila_root = nullptr;
int (*g_handle_run)(const VoiladRunRequest *, VoiladRunCallbacks *) = nullptr;

class WorkerServiceImpl final : public voila::v1::Worker::Service {
public:
    grpc::Status Run(grpc::ServerContext *ctx,
                     grpc::ServerReaderWriter<voila::v1::RunOutput, voila::v1::RunInput> *stream) override {
        voila::v1::RunInput first;
        if (!stream->Read(&first)) {
            return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "missing first RunInput");
        }
        if (!first.has_spec()) {
            return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "first Run message must be RunSpec");
        }
        const auto &spec = first.spec();

        struct CbCtx {
            grpc::ServerReaderWriter<voila::v1::RunOutput, voila::v1::RunInput> *stream;
            bool client_gone = false;
        } cb_ctx{stream};

        VoiladRunCallbacks cb{};
        cb.ctx = &cb_ctx;
        cb.on_context_id = [](void *ctx, const char *id) -> int {
            auto *c = static_cast<CbCtx *>(ctx);
            voila::v1::RunOutput out;
            out.set_context_id(id);
            if (!c->stream->Write(out)) {
                c->client_gone = true;
                return -1;
            }
            return 0;
        };
        cb.on_stdout = [](void *ctx, const uint8_t *data, size_t len) -> int {
            auto *c = static_cast<CbCtx *>(ctx);
            voila::v1::RunOutput out;
            out.set_stdout(std::string(reinterpret_cast<const char *>(data), len));
            if (!c->stream->Write(out)) {
                c->client_gone = true;
                return -1;
            }
            return 0;
        };
        cb.on_stderr = [](void *ctx, const uint8_t *data, size_t len) -> int {
            auto *c = static_cast<CbCtx *>(ctx);
            voila::v1::RunOutput out;
            out.set_stderr(std::string(reinterpret_cast<const char *>(data), len));
            if (!c->stream->Write(out)) {
                c->client_gone = true;
                return -1;
            }
            return 0;
        };
        cb.on_exit = [](void *ctx, int32_t code) -> int {
            auto *c = static_cast<CbCtx *>(ctx);
            voila::v1::RunOutput out;
            out.set_exit_code(code);
            if (!c->stream->Write(out)) {
                c->client_gone = true;
                return -1;
            }
            return 0;
        };

        std::vector<const char *> arg_ptrs;
        arg_ptrs.reserve(spec.args_size());
        for (int i = 0; i < spec.args_size(); i++) {
            arg_ptrs.push_back(spec.args(i).c_str());
        }
        VoiladRunRequest req{};
        req.image = spec.image().c_str();
        req.args = arg_ptrs.empty() ? nullptr : arg_ptrs.data();
        req.args_len = arg_ptrs.size();
        req.memory_limit_bytes = spec.memory_limit_bytes();
        req.cpu_quota_percent = spec.cpu_quota_percent();
        req.attach_stdin = spec.attach_stdin() ? 1 : 0;

        std::thread stdin_thread;
        if (req.attach_stdin) {
            stdin_thread = std::thread([stream, &cb_ctx]() {
                voila::v1::RunInput in;
                while (stream->Read(&in)) {
                    if (in.has_stdin_eof()) break;
                    if (in.has_stdin()) {
                        // stdin pump not wired for v0 proof; attach_stdin=false in tests
                    }
                }
            });
        }

        int rc = g_handle_run(&req, &cb);
        if (stdin_thread.joinable()) stdin_thread.join();
        if (rc != 0) {
            return grpc::Status(grpc::StatusCode::ABORTED, "run failed");
        }
        return grpc::Status::OK;
    }
};

} // namespace

extern "C" int voilad_grpc_serve_unix(const char *socket_path, const char *voila_root,
                                      int (*handle_run)(const VoiladRunRequest *, VoiladRunCallbacks *)) {
    if (!socket_path || !voila_root || !handle_run) return 1;
    g_voila_root = voila_root;
    g_handle_run = handle_run;

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::string addr = std::string("unix://") + socket_path;
    WorkerServiceImpl service;
    grpc::ServerBuilder builder;
    builder.AddListeningPort(addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&service);
    std::unique_ptr<grpc::Server> server(builder.BuildAndStart());
    if (!server) return 2;
    chmod(socket_path, 0666);

    while (!g_stop) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    server->Shutdown();
    return 0;
}
