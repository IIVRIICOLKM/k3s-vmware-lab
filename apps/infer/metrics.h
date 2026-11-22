// Counters exposed at GET /metrics in the Prometheus text format (scraped by Prometheus, weeks 12-14).
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

struct Config;

struct Metrics {
  std::atomic<uint64_t> ok{0}, rejected{0}, timeout{0}, bad_request{0}, failed{0};
  std::atomic<uint64_t> batches{0}, batched{0};
  std::atomic<uint64_t> latency_us_sum{0};
  std::atomic<uint64_t> compute_us_sum{0};  // time spent inside Executor::run, per batch
  static constexpr size_t kBuckets = 6;     // batch size histogram: 1, 2, 4, 8, 16, +Inf
  std::atomic<uint64_t> batch_le[kBuckets]{};

  void observe_batch(size_t n, uint64_t compute_us);

  // Prometheus text for the current values.
  std::string render(const Config &cfg, size_t queue_len, const std::string &device, const std::string &gpu) const;
};
