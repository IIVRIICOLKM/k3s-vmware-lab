// Unit test of the inference worker's /metrics text (apps/infer/metrics.cpp): the request latency histogram
// k3slab_infer_request_seconds_bucket/_sum/_count and the metric names that existed before it.
// Built and run by scripts/jenkins-stage-cpp.sh (Jenkins stage "C++"), no CUDA, no network, no test framework:
//   g++ -std=c++20 -Wall -Wextra -I apps/infer tests/infer/test_metrics.cpp apps/infer/metrics.cpp
//       apps/infer/config.cpp apps/infer/util.cpp -pthread -o test_metrics && ./test_metrics   (one command line)
//
// [한국어 설명] metrics.cpp의 지연 히스토그램 단위 시험. 경계값(500us가 le=0.0005에 들어가는지), 누적 값이 줄지 않는지,
//   +Inf와 _count가 같은지, 여러 스레드가 동시에 기록해도 개수가 맞는지, 예전 지표 이름이 그대로인지 본다.
//   실패하면 실패한 검사의 줄 번호와 식을 출력하고 종료 코드 1이다. 단위 시험은 이미지 빌드 폴더(apps/infer) 밖(tests/infer)에 둔다
//   (tests/train과 같은 이유: scripts/image-build.sh가 빌드 폴더의 하위 폴더를 거부하고, 시험 파일이 이미지 컨텍스트에 섞이지 않게).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <thread>
#include <vector>

#include "config.h"
#include "metrics.h"

static int failures = 0;
#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);   \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

// The text /metrics would return for these metrics (queue 0, cpu worker).
static std::string render(const Metrics &m) {
  Config cfg;
  return m.render(cfg, 0, "cpu", "");
}

// The value of the first line that starts with `prefix` (e.g. `k3slab_infer_request_seconds_count `), or "" when absent.
static std::string value_of(const std::string &text, const std::string &prefix) {
  size_t at = 0;
  while ((at = text.find(prefix, at)) != std::string::npos) {
    if (at == 0 || text[at - 1] == '\n') {
      size_t end = text.find('\n', at);
      return text.substr(at + prefix.size(), end - at - prefix.size());
    }
    at += prefix.size();
  }
  return "";
}

// All histogram buckets in order: le label -> cumulative count.
static std::vector<std::pair<std::string, unsigned long long>> buckets(const std::string &text) {
  std::vector<std::pair<std::string, unsigned long long>> out;
  const std::string head = "k3slab_infer_request_seconds_bucket{le=\"";
  size_t at = 0;
  while ((at = text.find(head, at)) != std::string::npos) {
    size_t q = text.find('"', at + head.size());
    size_t end = text.find('\n', q);
    out.emplace_back(text.substr(at + head.size(), q - at - head.size()),
                     std::strtoull(text.c_str() + q + 3, nullptr, 10));  // after `"} `
    at = end;
  }
  return out;
}

static void test_empty() {
  Metrics m;
  std::string t = render(m);
  CHECK(t.find("# TYPE k3slab_infer_request_seconds histogram\n") != std::string::npos);
  auto b = buckets(t);
  CHECK(b.size() == LatencyHistogram::kBounds + 1);
  for (auto &x : b) CHECK(x.second == 0);
  CHECK(b.back().first == "+Inf");
  CHECK(value_of(t, "k3slab_infer_request_seconds_sum ") == "0.000000");
  CHECK(value_of(t, "k3slab_infer_request_seconds_count ") == "0");
}

// A value equal to a bound belongs to that bucket (`le` means <=); one microsecond more belongs to the next one.
static void test_boundaries() {
  const uint64_t bounds[] = {500, 1000, 2000, 5000, 10000, 25000, 50000, 100000, 250000, 500000, 1000000, 2000000};
  for (size_t i = 0; i < LatencyHistogram::kBounds; ++i) {
    CHECK(LatencyHistogram::kBoundsUs[i] == bounds[i]);
    Metrics at, above;
    at.latency_us_sum += bounds[i];
    above.latency_us_sum += bounds[i] + 1;
    CHECK(at.latency_us_sum.bucket(i) == 1);                      // exactly on the bound: this bucket
    CHECK(above.latency_us_sum.bucket(i) == 0);                   // one microsecond more: not this bucket ...
    CHECK(above.latency_us_sum.bucket(i + 1) == 1);               // ... the next one (or +Inf after the last bound)
  }
  // Rendered form: 500 us is in le="0.0005" and in every larger bucket; 2000001 us only in +Inf.
  Metrics m;
  m.latency_us_sum += 500;
  m.latency_us_sum += 2000001;
  auto b = buckets(render(m));
  CHECK(b.size() == 13);
  CHECK(b[0].first == "0.0005" && b[0].second == 1);
  CHECK(b[11].first == "2" && b[11].second == 1);
  CHECK(b[12].first == "+Inf" && b[12].second == 2);
}

static void test_labels() {
  Metrics m;
  auto b = buckets(render(m));
  const char *want[] = {"0.0005", "0.001", "0.002", "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2", "+Inf"};
  CHECK(b.size() == 13);
  for (size_t i = 0; i < b.size() && i < 13; ++i) CHECK(b[i].first == want[i]);
}

// Cumulative counts never decrease, +Inf == _count, _sum is the summed seconds.
static void test_cumulative_sum_count() {
  Metrics m;
  uint64_t total_us = 0, n = 0;
  uint64_t x = 12345;
  for (int i = 0; i < 5000; ++i) {
    x = x * 6364136223846793005ULL + 1442695040888963407ULL;  // fixed pseudo-random sequence
    uint64_t us = (x >> 33) % 3000000;                         // 0 .. 3 s, some above the last bound
    m.latency_us_sum += us;
    total_us += us;
    ++n;
  }
  std::string t = render(m);
  auto b = buckets(t);
  CHECK(b.size() == 13);
  for (size_t i = 1; i < b.size(); ++i) CHECK(b[i].second >= b[i - 1].second);
  CHECK(b.back().second == n);
  CHECK(value_of(t, "k3slab_infer_request_seconds_count ") == std::to_string(n));
  char want[64];
  std::snprintf(want, sizeof want, "%.6f", static_cast<double>(total_us) / 1e6);
  CHECK(value_of(t, "k3slab_infer_request_seconds_sum ") == want);
  CHECK(m.latency_us_sum.sum_us() == total_us);
}

// Worker threads observe at the same time: nothing is lost.
static void test_threads() {
  Metrics m;
  const int kThreads = 4, kEach = 20000;
  std::vector<std::thread> ts;
  for (int t = 0; t < kThreads; ++t)
    ts.emplace_back([&m, t] {
      for (int i = 0; i < kEach; ++i) m.latency_us_sum += static_cast<uint64_t>(300 + 400 * t + i % 7);
    });
  for (auto &t : ts) t.join();
  auto b = buckets(render(m));
  CHECK(b.back().second == static_cast<unsigned long long>(kThreads) * kEach);
  for (size_t i = 1; i < b.size(); ++i) CHECK(b[i].second >= b[i - 1].second);
}

// The metric names and meanings that existed before the histogram are unchanged.
static void test_existing_names() {
  Metrics m;
  m.ok += 3;
  m.rejected += 1;
  m.observe_batch(3, 1500);
  m.latency_us_sum += 1000;
  m.latency_us_sum += 2000;
  m.latency_us_sum += 3000;
  std::string t = render(m);
  const char *lines[] = {
      "k3slab_infer_info{device=\"cpu\",gpu=\"\",model_version=\"",
      "k3slab_infer_queue_length 0\n",
      "k3slab_infer_queue_capacity ",
      "k3slab_infer_worker_threads ",
      "k3slab_infer_requests_total{result=\"ok\"} 3\n",
      "k3slab_infer_requests_total{result=\"rejected\"} 1\n",
      "k3slab_infer_requests_total{result=\"timeout\"} 0\n",
      "k3slab_infer_requests_total{result=\"bad_request\"} 0\n",
      "k3slab_infer_requests_total{result=\"failed\"} 0\n",
      "# TYPE k3slab_infer_batch_size histogram\n",
      "k3slab_infer_batch_size_bucket{le=\"4\"} 1\n",
      "k3slab_infer_batch_size_sum 3\n",
      "k3slab_infer_batch_size_count 1\n",
      "k3slab_infer_batch_compute_seconds_sum 0.001500\n",
      "k3slab_infer_batch_compute_seconds_count 1\n",
      "k3slab_infer_request_seconds_sum 0.006000\n",
      "k3slab_infer_request_seconds_count 3\n",
  };
  for (const char *l : lines) CHECK(t.find(l) != std::string::npos);
  // 1 ms, 2 ms, 3 ms: le=0.001 holds one, le=0.002 two, le=0.005 all three.
  auto b = buckets(t);
  CHECK(b[1].second == 1 && b[2].second == 2 && b[3].second == 3);
}

int main() {
  test_empty();
  test_boundaries();
  test_labels();
  test_cumulative_sum_count();
  test_threads();
  test_existing_names();
  if (failures != 0) {
    std::fprintf(stderr, "test_metrics: %d check(s) failed\n", failures);
    return 1;
  }
  std::printf("test_metrics: all checks passed\n");
  return 0;
}
