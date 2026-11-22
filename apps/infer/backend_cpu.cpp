// CPU backend: the same per-sample loop the worker used before the GPU path (v0.1).
#include "backend.h"

namespace {

class CpuExecutor : public Executor {
 public:
  explicit CpuExecutor(const Model &m) : model_(m) {}
  void run(const std::vector<const std::vector<float> *> &xs, std::vector<std::vector<float>> &logits) override {
    logits.resize(xs.size());
    for (size_t i = 0; i < xs.size(); ++i) logits[i] = model_.logits(*xs[i]);
  }

 private:
  const Model &model_;
};

class CpuBackend : public Backend {
 public:
  explicit CpuBackend(const Model &m) : model_(m) {}
  std::string device() const override { return "cpu"; }
  std::string description() const override { return "cpu"; }
  std::unique_ptr<Executor> executor(size_t) const override { return std::make_unique<CpuExecutor>(model_); }

 private:
  const Model &model_;
};

}  // namespace

std::unique_ptr<Backend> make_cpu_backend(const Model &model) { return std::make_unique<CpuBackend>(model); }
