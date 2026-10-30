// k3slab inference worker (proposal slide 10): a bounded request queue served by a fixed number of worker threads
// that run requests in batches, with a per-request timeout.
//
//   POST /infer   {"x":[64 floats]}  -> 200 {"class":k,"probs":[...],"batch":n,"queue_ms":t,"model_version":v}
//                                       429 when the queue is full (rejected at once, never left waiting)
//                                       504 when the request waited longer than TIMEOUT_MS
//                                       400 on a malformed body
//   GET  /healthz                     -> 200 once the model is loaded
//   GET  /metrics                     -> Prometheus text: queue length, results, batch sizes, latency
//
// The model is the classifier trained by apps/train/train.py, exported there as plain float32 weights (model.k3sm),
// so this worker needs no ML runtime. Inference itself runs on the CPU for now; WORK_MS adds a fixed cost per batch
// as a stand-in for one GPU call, which is what makes batching (and queue overflow) observable with a tiny model.
//
// Configuration (environment): MAX_QUEUE=100 MAX_BATCH=8 WORKER_THREADS=2 TIMEOUT_MS=2000 WORK_MS=20 PORT=8080
//                              MODEL_PATH=/models/model.k3sm MODEL_VERSION=unknown

#include "httplib.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <csignal>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <future>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;

namespace {

long env_long(const char *name, long fallback, long min, long max) {
  const char *v = std::getenv(name);
  if (v == nullptr || *v == '\0') return fallback;
  char *end = nullptr;
  long n = std::strtol(v, &end, 10);
  if (*end != '\0' || n < min || n > max) {
    std::fprintf(stderr, "invalid %s=%s (allowed %ld..%ld)\n", name, v, min, max);
    std::exit(2);
  }
  return n;
}

std::string env_str(const char *name, const char *fallback) {
  const char *v = std::getenv(name);
  return (v != nullptr && *v != '\0') ? v : fallback;
}

struct Config {
  size_t max_queue = static_cast<size_t>(env_long("MAX_QUEUE", 100, 1, 100000));
  size_t max_batch = static_cast<size_t>(env_long("MAX_BATCH", 8, 1, 1024));
  size_t threads = static_cast<size_t>(env_long("WORKER_THREADS", 2, 1, 64));
  long timeout_ms = env_long("TIMEOUT_MS", 2000, 1, 600000);
  long work_ms = env_long("WORK_MS", 20, 0, 60000);
  int port = static_cast<int>(env_long("PORT", 8080, 1, 65535));
  std::string model_path = env_str("MODEL_PATH", "/models/model.k3sm");
  std::string model_version = env_str("MODEL_VERSION", "unknown");
};

// ---------------------------------------------------------------------------------------------------------------
// Model: Linear layers with ReLU in between, read from the K3SM file written by train.py's export_raw().

struct Layer {
  uint32_t out = 0, in = 0;
  std::vector<float> w, b;  // w is row-major [out][in]
};

class Model {
 public:
  static Model load(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open " + path);
    char magic[4];
    uint32_t version = 0, count = 0;
    f.read(magic, 4);
    f.read(reinterpret_cast<char *>(&version), 4);
    f.read(reinterpret_cast<char *>(&count), 4);
    if (!f || std::memcmp(magic, "K3SM", 4) != 0 || version != 1 || count == 0 || count > 64)
      throw std::runtime_error(path + " is not a K3SM v1 model");
    Model m;
    for (uint32_t i = 0; i < count; ++i) {
      Layer l;
      f.read(reinterpret_cast<char *>(&l.out), 4);
      f.read(reinterpret_cast<char *>(&l.in), 4);
      if (!f || l.out == 0 || l.in == 0 || l.out > 65536 || l.in > 65536)
        throw std::runtime_error("bad layer header in " + path);
      if (!m.layers_.empty() && m.layers_.back().out != l.in)
        throw std::runtime_error("layer sizes do not chain in " + path);
      l.w.resize(static_cast<size_t>(l.out) * l.in);
      l.b.resize(l.out);
      f.read(reinterpret_cast<char *>(l.w.data()), static_cast<std::streamsize>(l.w.size() * sizeof(float)));
      f.read(reinterpret_cast<char *>(l.b.data()), static_cast<std::streamsize>(l.b.size() * sizeof(float)));
      if (!f) throw std::runtime_error("truncated model " + path);
      m.layers_.push_back(std::move(l));
    }
    if (f.peek() != EOF) throw std::runtime_error("trailing bytes in " + path);
    return m;
  }

  size_t input_dim() const { return layers_.front().in; }
  size_t output_dim() const { return layers_.back().out; }

  // Forward pass for one sample; returns softmax probabilities.
  std::vector<float> forward(const std::vector<float> &x) const {
    std::vector<float> cur = x, next;
    for (size_t li = 0; li < layers_.size(); ++li) {
      const Layer &l = layers_[li];
      next.assign(l.out, 0.0f);
      for (uint32_t o = 0; o < l.out; ++o) {
        const float *row = &l.w[static_cast<size_t>(o) * l.in];
        float acc = l.b[o];
        for (uint32_t i = 0; i < l.in; ++i) acc += row[i] * cur[i];
        next[o] = (li + 1 < layers_.size()) ? std::max(acc, 0.0f) : acc;  // ReLU except after the last layer
      }
      cur.swap(next);
    }
    float mx = *std::max_element(cur.begin(), cur.end()), sum = 0.0f;
    for (float &v : cur) sum += (v = std::exp(v - mx));
    for (float &v : cur) v /= sum;
    return cur;
  }

 private:
  std::vector<Layer> layers_;
};

// ---------------------------------------------------------------------------------------------------------------
// Request queue: bounded, so overload is rejected at the door instead of piling up latency.

struct Result {
  int status = 500;
  std::string body;
};

struct Request {
  std::vector<float> x;
  Clock::time_point enqueued = Clock::now();
  std::promise<Result> done;
};
using RequestPtr = std::shared_ptr<Request>;

class Queue {
 public:
  explicit Queue(size_t capacity) : capacity_(capacity) {}

  // False when the queue is full (or shutting down): the caller answers 429 immediately.
  bool push(RequestPtr r) {
    {
      std::lock_guard<std::mutex> lk(m_);
      if (closed_ || q_.size() >= capacity_) return false;
      q_.push_back(std::move(r));
    }
    cv_.notify_one();
    return true;
  }

  // Blocks until work is available, then takes up to max_batch requests at once. Empty result = shut down.
  std::vector<RequestPtr> pop_batch(size_t max_batch) {
    std::unique_lock<std::mutex> lk(m_);
    cv_.wait(lk, [&] { return closed_ || !q_.empty(); });
    std::vector<RequestPtr> batch;
    while (!q_.empty() && batch.size() < max_batch) {
      batch.push_back(std::move(q_.front()));
      q_.pop_front();
    }
    return batch;
  }

  size_t size() {
    std::lock_guard<std::mutex> lk(m_);
    return q_.size();
  }

  void close() {
    {
      std::lock_guard<std::mutex> lk(m_);
      closed_ = true;
    }
    cv_.notify_all();
  }

 private:
  std::mutex m_;
  std::condition_variable cv_;
  std::deque<RequestPtr> q_;
  size_t capacity_;
  bool closed_ = false;
};

// ---------------------------------------------------------------------------------------------------------------
// Metrics (Prometheus text format, scraped later by Prometheus/Grafana, weeks 12-14).

struct Metrics {
  std::atomic<uint64_t> ok{0}, rejected{0}, timeout{0}, bad_request{0};
  std::atomic<uint64_t> batches{0}, batched{0};
  std::atomic<uint64_t> latency_us_sum{0};
  static constexpr size_t kBuckets = 6;  // batch size histogram: 1, 2, 4, 8, 16, +Inf
  std::atomic<uint64_t> batch_le[kBuckets]{};

  void observe_batch(size_t n) {
    static const size_t bounds[kBuckets - 1] = {1, 2, 4, 8, 16};
    batches++;
    batched += n;
    for (size_t i = 0; i < kBuckets; ++i)
      if (i == kBuckets - 1 || n <= bounds[i]) batch_le[i]++;
  }
};

std::string fmt(const char *f, ...) __attribute__((format(printf, 1, 2)));
std::string fmt(const char *f, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, f);
  std::vsnprintf(buf, sizeof buf, f, ap);
  va_end(ap);
  return buf;
}

std::string error_json(const char *msg, size_t queue_len) {
  return fmt("{\"error\":\"%s\",\"queue\":%zu}", msg, queue_len);
}

// Parses {"x":[f, f, ...]}: takes the numbers between the first '[' and the following ']'.
bool parse_input(const std::string &body, std::vector<float> &out) {
  size_t open = body.find('['), close = body.find(']', open == std::string::npos ? 0 : open);
  if (open == std::string::npos || close == std::string::npos) return false;
  std::string inner = body.substr(open + 1, close - open - 1);
  const char *p = inner.c_str();
  while (*p != '\0') {
    while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\t' || *p == '\r') ++p;
    if (*p == '\0') break;
    char *end = nullptr;
    float v = std::strtof(p, &end);
    if (end == p || !std::isfinite(v)) return false;
    out.push_back(v);
    p = end;
  }
  return true;
}

void worker_loop(const Config &cfg, const Model &model, Queue &queue, Metrics &metrics) {
  const auto timeout = std::chrono::milliseconds(cfg.timeout_ms);
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

    // One fixed cost per batch (stand-in for a single GPU call), then the per-sample compute.
    if (cfg.work_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(cfg.work_ms));
    metrics.observe_batch(live.size());
    for (auto &r : live) {
      std::vector<float> probs = model.forward(r->x);
      size_t cls = static_cast<size_t>(std::max_element(probs.begin(), probs.end()) - probs.begin());
      auto waited = Clock::now() - r->enqueued;
      long queue_ms = std::chrono::duration_cast<std::chrono::milliseconds>(waited).count();
      std::string body = fmt("{\"class\":%zu,\"batch\":%zu,\"queue_ms\":%ld,\"model_version\":\"%s\",\"probs\":[",
                             cls, live.size(), queue_ms, cfg.model_version.c_str());
      for (size_t i = 0; i < probs.size(); ++i) body += fmt(i ? ",%.5f" : "%.5f", probs[i]);
      body += "]}";
      metrics.ok++;
      metrics.latency_us_sum += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(waited).count());
      r->done.set_value({200, std::move(body)});
    }
  }
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
  try {
    model = Model::load(cfg.model_path);
  } catch (const std::exception &e) {
    std::fprintf(stderr, "model load failed: %s\n", e.what());
    return 1;
  }
  std::printf("k3slab-infer: model %s (%s) in=%zu out=%zu; MAX_QUEUE=%zu MAX_BATCH=%zu WORKER_THREADS=%zu "
              "TIMEOUT_MS=%ld WORK_MS=%ld PORT=%d\n",
              cfg.model_path.c_str(), cfg.model_version.c_str(), model.input_dim(), model.output_dim(), cfg.max_queue,
              cfg.max_batch, cfg.threads, cfg.timeout_ms, cfg.work_ms, cfg.port);
  std::fflush(stdout);

  Queue queue(cfg.max_queue);
  Metrics metrics;
  std::vector<std::thread> workers;
  for (size_t i = 0; i < cfg.threads; ++i)
    workers.emplace_back(worker_loop, std::cref(cfg), std::cref(model), std::ref(queue), std::ref(metrics));

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

  svr.Get("/metrics", [&](const httplib::Request &, httplib::Response &res) {
    std::string m;
    m += "# HELP k3slab_infer_queue_length Requests waiting in the queue.\n# TYPE k3slab_infer_queue_length gauge\n";
    m += fmt("k3slab_infer_queue_length %zu\n", queue.size());
    m += "# HELP k3slab_infer_queue_capacity MAX_QUEUE.\n# TYPE k3slab_infer_queue_capacity gauge\n";
    m += fmt("k3slab_infer_queue_capacity %zu\n", cfg.max_queue);
    m += "# HELP k3slab_infer_worker_threads WORKER_THREADS.\n# TYPE k3slab_infer_worker_threads gauge\n";
    m += fmt("k3slab_infer_worker_threads %zu\n", cfg.threads);
    m += "# HELP k3slab_infer_requests_total Requests by result.\n# TYPE k3slab_infer_requests_total counter\n";
    m += fmt("k3slab_infer_requests_total{result=\"ok\"} %llu\n", (unsigned long long)metrics.ok.load());
    m += fmt("k3slab_infer_requests_total{result=\"rejected\"} %llu\n", (unsigned long long)metrics.rejected.load());
    m += fmt("k3slab_infer_requests_total{result=\"timeout\"} %llu\n", (unsigned long long)metrics.timeout.load());
    m += fmt("k3slab_infer_requests_total{result=\"bad_request\"} %llu\n", (unsigned long long)metrics.bad_request.load());
    m += "# HELP k3slab_infer_batch_size Requests per executed batch.\n# TYPE k3slab_infer_batch_size histogram\n";
    static const char *le[Metrics::kBuckets] = {"1", "2", "4", "8", "16", "+Inf"};
    for (size_t i = 0; i < Metrics::kBuckets; ++i)
      m += fmt("k3slab_infer_batch_size_bucket{le=\"%s\"} %llu\n", le[i], (unsigned long long)metrics.batch_le[i].load());
    m += fmt("k3slab_infer_batch_size_sum %llu\n", (unsigned long long)metrics.batched.load());
    m += fmt("k3slab_infer_batch_size_count %llu\n", (unsigned long long)metrics.batches.load());
    m += "# HELP k3slab_infer_request_seconds Queue+compute time of successful requests.\n";
    m += "# TYPE k3slab_infer_request_seconds summary\n";
    m += fmt("k3slab_infer_request_seconds_sum %.6f\n", metrics.latency_us_sum.load() / 1e6);
    m += fmt("k3slab_infer_request_seconds_count %llu\n", (unsigned long long)metrics.ok.load());
    res.set_content(m, "text/plain; version=0.0.4");
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
