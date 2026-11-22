#include "worker.h"

#include <algorithm>
#include <cstdio>
#include <exception>
#include <thread>

#include "util.h"

void worker_loop(const Config &cfg, const Backend &backend, Queue &queue, Metrics &metrics) {
  const auto timeout = std::chrono::milliseconds(cfg.timeout_ms);
  std::unique_ptr<Executor> exec = backend.executor(cfg.max_batch);
  const std::string device = backend.device();
  std::vector<const std::vector<float> *> inputs;
  std::vector<std::vector<float>> logits;
  for (;;) {
    std::vector<RequestPtr> batch = queue.pop_batch(cfg.max_batch);
    if (batch.empty()) return;  // queue closed

    // Requests that already waited past the deadline are failed, not run.
    auto now = Clock::now();
    std::vector<RequestPtr> live;
    for (auto &r : batch) {
      if (now - r->enqueued > timeout) {
        metrics.timeout++;
        r->done.set_value({504, error_json("timed out in queue", queue.size())});
      } else {
        live.push_back(r);
      }
    }
    if (live.empty()) continue;

    // WORK_MS: optional fixed cost per batch. It stood in for one GPU call while the worker was CPU-only (v0.1) and
    // is kept so the old batch/overload benchmark can be repeated; with the real GPU path it is set to 0.
    if (cfg.work_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(cfg.work_ms));
    inputs.clear();
    for (auto &r : live) inputs.push_back(&r->x);
    auto started = Clock::now();
    try {
      exec->run(inputs, logits);
    } catch (const std::exception &e) {
      std::fprintf(stderr, "k3slab-infer: batch of %zu failed: %s\n", live.size(), e.what());
      for (auto &r : live) {
        metrics.failed++;
        r->done.set_value({500, error_json("inference failed", queue.size())});
      }
      continue;
    }
    auto compute_us = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - started).count();
    metrics.observe_batch(live.size(), static_cast<uint64_t>(compute_us));

    for (size_t k = 0; k < live.size(); ++k) {
      auto &r = live[k];
      std::vector<float> &probs = logits[k];
      softmax(probs);
      size_t cls = static_cast<size_t>(std::max_element(probs.begin(), probs.end()) - probs.begin());
      auto waited = Clock::now() - r->enqueued;
      long queue_ms = std::chrono::duration_cast<std::chrono::milliseconds>(waited).count();
      std::string body = fmt("{\"class\":%zu,\"batch\":%zu,\"queue_ms\":%ld,\"device\":\"%s\",\"model_version\":\"%s\",\"probs\":[",
                             cls, live.size(), queue_ms, device.c_str(), cfg.model_version.c_str());
      for (size_t i = 0; i < probs.size(); ++i) body += fmt(i ? ",%.5f" : "%.5f", probs[i]);
      body += "]}";
      metrics.ok++;
      metrics.latency_us_sum += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(waited).count());
      r->done.set_value({200, std::move(body)});
    }
  }
}
