#include "metrics.h"

#include "config.h"
#include "util.h"

void Metrics::observe_batch(size_t n, uint64_t compute_us) {
  static const size_t bounds[kBuckets - 1] = {1, 2, 4, 8, 16};
  batches++;
  batched += n;
  compute_us_sum += compute_us;
  for (size_t i = 0; i < kBuckets; ++i)
    if (i == kBuckets - 1 || n <= bounds[i]) batch_le[i]++;
}

void LatencyHistogram::observe(uint64_t us) {
  // First bound that is >= us (so a value equal to a bound lands in that bucket); kBounds = above every bound (+Inf only).
  size_t i = 0;
  while (i < kBounds && us > kBoundsUs[i]) ++i;
  bucket_[i]++;
  sum_us_ += us;
}

void LatencyHistogram::render(std::string &out) const {
  out += "# HELP k3slab_infer_request_seconds Queue+compute time of successful requests.\n";
  out += "# TYPE k3slab_infer_request_seconds histogram\n";
  // Cumulative `le` counts from the per-bucket counters. _count is the +Inf total of this very read, so _count and
  // le="+Inf" always agree inside one scrape even while workers keep observing (the _sum may be a few requests ahead).
  unsigned long long cumulative = 0;
  for (size_t i = 0; i < kBounds; ++i) {
    cumulative += bucket_[i].load();
    out += fmt("k3slab_infer_request_seconds_bucket{le=\"%g\"} %llu\n", static_cast<double>(kBoundsUs[i]) / 1e6, cumulative);
  }
  cumulative += bucket_[kBounds].load();
  out += fmt("k3slab_infer_request_seconds_bucket{le=\"+Inf\"} %llu\n", cumulative);
  out += fmt("k3slab_infer_request_seconds_sum %.6f\n", static_cast<double>(sum_us_.load()) / 1e6);
  out += fmt("k3slab_infer_request_seconds_count %llu\n", cumulative);
}

std::string Metrics::render(const Config &cfg, size_t queue_len, const std::string &device,
                            const std::string &gpu) const {
  auto u = [](const std::atomic<uint64_t> &v) { return static_cast<unsigned long long>(v.load()); };
  std::string m;
  m += "# HELP k3slab_infer_info Device the worker computes on.\n# TYPE k3slab_infer_info gauge\n";
  m += fmt("k3slab_infer_info{device=\"%s\",gpu=\"%s\",model_version=\"%s\"} 1\n", device.c_str(), gpu.c_str(),
           cfg.model_version.c_str());
  m += "# HELP k3slab_infer_queue_length Requests waiting in the queue.\n# TYPE k3slab_infer_queue_length gauge\n";
  m += fmt("k3slab_infer_queue_length %zu\n", queue_len);
  m += "# HELP k3slab_infer_queue_capacity MAX_QUEUE.\n# TYPE k3slab_infer_queue_capacity gauge\n";
  m += fmt("k3slab_infer_queue_capacity %zu\n", cfg.max_queue);
  m += "# HELP k3slab_infer_worker_threads WORKER_THREADS.\n# TYPE k3slab_infer_worker_threads gauge\n";
  m += fmt("k3slab_infer_worker_threads %zu\n", cfg.threads);
  m += "# HELP k3slab_infer_requests_total Requests by result.\n# TYPE k3slab_infer_requests_total counter\n";
  m += fmt("k3slab_infer_requests_total{result=\"ok\"} %llu\n", u(ok));
  m += fmt("k3slab_infer_requests_total{result=\"rejected\"} %llu\n", u(rejected));
  m += fmt("k3slab_infer_requests_total{result=\"timeout\"} %llu\n", u(timeout));
  m += fmt("k3slab_infer_requests_total{result=\"bad_request\"} %llu\n", u(bad_request));
  m += fmt("k3slab_infer_requests_total{result=\"failed\"} %llu\n", u(failed));
  m += "# HELP k3slab_infer_batch_size Requests per executed batch.\n# TYPE k3slab_infer_batch_size histogram\n";
  static const char *le[kBuckets] = {"1", "2", "4", "8", "16", "+Inf"};
  for (size_t i = 0; i < kBuckets; ++i)
    m += fmt("k3slab_infer_batch_size_bucket{le=\"%s\"} %llu\n", le[i], u(batch_le[i]));
  m += fmt("k3slab_infer_batch_size_sum %llu\n", u(batched));
  m += fmt("k3slab_infer_batch_size_count %llu\n", u(batches));
  m += "# HELP k3slab_infer_batch_compute_seconds Time spent computing batches (CPU or GPU).\n";
  m += "# TYPE k3slab_infer_batch_compute_seconds summary\n";
  m += fmt("k3slab_infer_batch_compute_seconds_sum %.6f\n", compute_us_sum.load() / 1e6);
  m += fmt("k3slab_infer_batch_compute_seconds_count %llu\n", u(batches));
  latency_us_sum.render(m);  // k3slab_infer_request_seconds: _bucket{le}, _sum, _count (was a summary with _sum and _count only)
  return m;
}
