// Where a batch is computed: the CPU (always available) or the GPU (CUDA, backend_cuda.cu).
// A Backend holds the read-only weights; every worker thread gets its own Executor (own buffers, and on the GPU its
// own stream), so worker threads never share mutable state.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "model.h"

class Executor {
 public:
  virtual ~Executor() = default;
  // Runs xs.size() (<= max_batch) samples together and writes one logits vector per sample.
  virtual void run(const std::vector<const std::vector<float> *> &xs, std::vector<std::vector<float>> &logits) = 0;
};

class Backend {
 public:
  virtual ~Backend() = default;
  virtual std::string device() const = 0;       // "cpu" or "cuda"
  virtual std::string description() const = 0;  // e.g. the GPU name, for the log and /metrics
  virtual std::unique_ptr<Executor> executor(size_t max_batch) const = 0;
};

std::unique_ptr<Backend> make_cpu_backend(const Model &model);

// Returns nullptr and sets `why` when no usable GPU is found (no driver, no device, or built without CUDA).
std::unique_ptr<Backend> make_cuda_backend(const Model &model, std::string &why);
