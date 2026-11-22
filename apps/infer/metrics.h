// Counters exposed at GET /metrics in the Prometheus text format (scraped by Prometheus, weeks 12-14).
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

struct Config;

// Latency of successful requests (queue wait + compute) as a Prometheus histogram: k3slab_infer_request_seconds
// _bucket{le}, _sum and _count. The dashboard's p50/p95 panels use histogram_quantile() over the buckets.
//
// Bucket bounds (seconds): 0.0005 0.001 0.002 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2 +Inf
//   - 0.5 ms .. 10 ms: the GPU path answers in about 1 ms on average (monitoring report 2026-11-22), so this is where p50 and
//     p95 sit; the 1-2-5 steps keep the estimate within a factor of two there.
//   - 25 ms .. 250 ms: the CPU worker with WORK_MS=20 (one batch costs at least 20 ms) and a short queue.
//   - 0.5 s .. 2 s: an overloaded queue. TIMEOUT_MS (default 2000) fails requests that waited longer, so a successful
//     request almost never lands above 2 s; if TIMEOUT_MS is raised, those requests fall into +Inf.
// Thirteen series per pod; the bounds are fixed so a rate() over a deploy that changes nothing else stays comparable.
class LatencyHistogram {
 public:
  static constexpr size_t kBounds = 12;
  // Upper bounds in microseconds (inclusive: an observation equal to a bound belongs to that bucket, as `le` means <=).
  static constexpr uint64_t kBoundsUs[kBounds] = {500,    1000,   2000,   5000,    10000,   25000,
                                                  50000,  100000, 250000, 500000, 1000000, 2000000};

  // Records one successful request that took `us` microseconds.
  void observe(uint64_t us);

  // `metrics.latency_us_sum += us` is how worker.cpp has always reported a latency, so `+=` records one observation.
  // (Before the histogram this member was a plain counter of the summed microseconds; the call site did not change.)
  LatencyHistogram &operator+=(uint64_t us) {
    observe(us);
    return *this;
  }

  // Sum of all observations in microseconds (the _sum series, in seconds).
  uint64_t sum_us() const { return sum_us_.load(); }

  // Per-bucket counts, NOT cumulative: bucket(i) counts observations with kBoundsUs[i-1] < us <= kBoundsUs[i];
  // bucket(kBounds) counts those above the last bound. render() accumulates them into Prometheus's cumulative `le` form.
  uint64_t bucket(size_t i) const { return bucket_[i].load(); }

  // Appends the histogram's lines (# HELP, # TYPE, _bucket, _sum, _count) to `out`.
  void render(std::string &out) const;

 private:
  std::atomic<uint64_t> bucket_[kBounds + 1]{};
  std::atomic<uint64_t> sum_us_{0};
};

struct Metrics {
  std::atomic<uint64_t> ok{0}, rejected{0}, timeout{0}, bad_request{0}, failed{0};
  std::atomic<uint64_t> batches{0}, batched{0};
  LatencyHistogram latency_us_sum;          // name kept: worker.cpp does `latency_us_sum += microseconds` (see above)
  std::atomic<uint64_t> compute_us_sum{0};  // time spent inside Executor::run, per batch
  static constexpr size_t kBuckets = 6;     // batch size histogram: 1, 2, 4, 8, 16, +Inf
  std::atomic<uint64_t> batch_le[kBuckets]{};

  void observe_batch(size_t n, uint64_t compute_us);

  // Prometheus text for the current values.
  std::string render(const Config &cfg, size_t queue_len, const std::string &device, const std::string &gpu) const;
};
