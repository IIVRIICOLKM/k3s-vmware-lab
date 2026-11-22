// Request queue: bounded, so overload is rejected at the door (HTTP 429) instead of piling up latency.
#pragma once

#include <chrono>
#include <condition_variable>
#include <deque>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using Clock = std::chrono::steady_clock;

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
