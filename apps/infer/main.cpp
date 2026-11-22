// k3slab inference worker (proposal slide 10): a bounded request queue served by a fixed number of worker threads
// that run requests in batches, with a per-request timeout. Batches run on the GPU (CUDA) when one is visible.
//
//   POST /infer   {"x":[64 floats]}  -> 200 {"class":k,"probs":[...],"batch":n,"queue_ms":t,"device":d,"model_version":v}
//                                       429 when the queue is full (rejected at once, never left waiting)
//                                       504 when the request waited longer than TIMEOUT_MS
//                                       400 on a malformed body
//   GET  /healthz                     -> 200 once the model is loaded
//   GET  /metrics                     -> Prometheus text: device, queue length, results, batch sizes, latency
//
// Files (flat on purpose: the in-cluster build ships this folder as a ConfigMap, which holds files only):
//   main.cpp      HTTP server, startup, shutdown           config.*   environment settings
//   model.*       K3SM model file and the CPU forward pass  queue.h    bounded request queue
//   backend.h     CPU/GPU interface                         backend_cpu.cpp, backend_cuda.cu (backend_nocuda.cpp)
//   worker.*      batch loop of one worker thread           metrics.*  /metrics counters   util.*  string helpers
//
// Configuration (environment): MAX_QUEUE=100 MAX_BATCH=8 WORKER_THREADS=2 TIMEOUT_MS=2000 WORK_MS=20 PORT=8080
//                              MODEL_PATH=/models/model.k3sm MODEL_VERSION=unknown DEVICE=auto|cuda|cpu

#include "httplib.h"

#include <algorithm>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <exception>
#include <memory>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "backend.h"
#include "config.h"
#include "metrics.h"
#include "model.h"
#include "queue.h"
#include "util.h"
#include "worker.h"

namespace {

// Picks the backend for DEVICE. auto falls back to the CPU (and says why), cuda refuses to start without a GPU.
std::unique_ptr<Backend> choose_backend(const Config &cfg, const Model &model) {
  if (cfg.device != "auto" && cfg.device != "cuda" && cfg.device != "cpu") {
    std::fprintf(stderr, "invalid DEVICE=%s (auto, cuda or cpu)\n", cfg.device.c_str());
    std::exit(2);
  }
  if (cfg.device != "cpu") {
    std::string why;
    std::unique_ptr<Backend> gpu = make_cuda_backend(model, why);
    if (gpu) return gpu;
    if (cfg.device == "cuda") {
      std::fprintf(stderr, "DEVICE=cuda but %s\n", why.c_str());
      std::exit(1);
    }
    std::printf("k3slab-infer: GPU not used (%s); computing on the CPU\n", why.c_str());
  }
  return make_cpu_backend(model);
}

// GPU results must match the CPU reference: run the same random batch through both and compare the logits.
// Float sums are added in a different order on the GPU, so allow a small relative difference.
bool self_test(const Backend &backend, const Model &model, size_t max_batch) {
  if (backend.device() == "cpu") return true;
  std::mt19937 rng(7);
  std::normal_distribution<float> dist(0.0f, 1.0f);
  const size_t n = std::min<size_t>(max_batch, 8);
  std::vector<std::vector<float>> xs(n, std::vector<float>(model.input_dim()));
  std::vector<const std::vector<float> *> ptrs;
  for (auto &x : xs) {
    for (float &v : x) v = dist(rng);
    ptrs.push_back(&x);
  }
  std::vector<std::vector<float>> gpu;
  backend.executor(n)->run(ptrs, gpu);
  double worst = 0.0;
  for (size_t s = 0; s < n; ++s) {
    std::vector<float> cpu = model.logits(xs[s]);
    for (size_t i = 0; i < cpu.size(); ++i)
      worst = std::max(worst, std::fabs(cpu[i] - gpu[s][i]) / (1.0 + std::fabs(cpu[i])));
  }
  std::printf("k3slab-infer: self-test %zu samples, max relative logit difference GPU vs CPU %.2e\n", n, worst);
  return worst < 1e-3;
}

}  // namespace

int main() {
  // Block SIGTERM/SIGINT in every thread; a dedicated thread waits for them and stops the server cleanly.
  sigset_t sigs;
  sigemptyset(&sigs);
  sigaddset(&sigs, SIGTERM);
  sigaddset(&sigs, SIGINT);
  pthread_sigmask(SIG_BLOCK, &sigs, nullptr);

  Config cfg;
  Model model;
  std::unique_ptr<Backend> backend;
  try {
    model = Model::load(cfg.model_path);
    backend = choose_backend(cfg, model);
    if (!self_test(*backend, model, cfg.max_batch)) {
      std::fprintf(stderr, "self-test failed: GPU results differ from the CPU reference\n");
      return 1;
    }
  } catch (const std::exception &e) {
    std::fprintf(stderr, "startup failed: %s\n", e.what());
    return 1;
  }
  std::printf("k3slab-infer: model %s (%s) in=%zu out=%zu layers=%zu macs/sample=%llu; device=%s (%s); "
              "MAX_QUEUE=%zu MAX_BATCH=%zu WORKER_THREADS=%zu TIMEOUT_MS=%ld WORK_MS=%ld PORT=%d\n",
              cfg.model_path.c_str(), cfg.model_version.c_str(), model.input_dim(), model.output_dim(),
              model.layers().size(), static_cast<unsigned long long>(model.macs()), backend->device().c_str(),
              backend->description().c_str(), cfg.max_queue, cfg.max_batch, cfg.threads, cfg.timeout_ms, cfg.work_ms,
              cfg.port);
  std::fflush(stdout);

  Queue queue(cfg.max_queue);
  Metrics metrics;
  std::vector<std::thread> workers;
  for (size_t i = 0; i < cfg.threads; ++i)
    workers.emplace_back(worker_loop, std::cref(cfg), std::cref(*backend), std::ref(queue), std::ref(metrics));

  httplib::Server svr;
  // Each waiting request holds an HTTP thread, so the pool must be larger than the queue; otherwise the HTTP layer,
  // not the queue, would become the limit and overload would never reach the rejection path.
  size_t http_threads = cfg.max_queue + cfg.threads * cfg.max_batch + 16;
  svr.new_task_queue = [http_threads] { return new httplib::ThreadPool(http_threads); };

  svr.Post("/infer", [&](const httplib::Request &req, httplib::Response &res) {
    auto r = std::make_shared<Request>();
    if (!parse_input(req.body, r->x) || r->x.size() != model.input_dim()) {
      metrics.bad_request++;
      res.status = 400;
      res.set_content(fmt("{\"error\":\"body must be {\\\"x\\\":[%zu numbers]}\"}", model.input_dim()), "application/json");
      return;
    }
    std::future<Result> fut = r->done.get_future();
    if (!queue.push(r)) {
      metrics.rejected++;
      res.status = 429;
      res.set_content(error_json("queue full", cfg.max_queue), "application/json");
      return;
    }
    // Safety net if workers stall: stop waiting a little after the queue deadline plus one batch.
    auto limit = std::chrono::milliseconds(cfg.timeout_ms + cfg.work_ms + 1000);
    if (fut.wait_for(limit) != std::future_status::ready) {
      metrics.timeout++;
      res.status = 504;
      res.set_content(error_json("timed out", queue.size()), "application/json");
      return;
    }
    Result out = fut.get();
    res.status = out.status;
    res.set_content(out.body, "application/json");
  });

  svr.Get("/healthz", [](const httplib::Request &, httplib::Response &res) { res.set_content("ok\n", "text/plain"); });

  const std::string device = backend->device(), gpu = backend->device() == "cuda" ? backend->description() : "";
  svr.Get("/metrics", [&](const httplib::Request &, httplib::Response &res) {
    res.set_content(metrics.render(cfg, queue.size(), device, gpu), "text/plain; version=0.0.4");
  });

  std::thread signal_thread([&] {
    int sig = 0;
    sigwait(&sigs, &sig);
    std::printf("k3slab-infer: signal %d, shutting down\n", sig);
    std::fflush(stdout);
    svr.stop();
  });

  bool ok = svr.listen("0.0.0.0", cfg.port);
  queue.close();
  for (auto &w : workers) w.join();
  if (signal_thread.joinable()) {
    if (ok) {
      signal_thread.join();
    } else {
      pthread_kill(signal_thread.native_handle(), SIGTERM);
      signal_thread.join();
    }
  }
  return ok ? 0 : 1;
}
