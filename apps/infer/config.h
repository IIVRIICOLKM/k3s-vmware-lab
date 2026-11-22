// Worker configuration, read once from the environment (see main.cpp for the list).
#pragma once

#include <cstddef>
#include <string>

long env_long(const char *name, long fallback, long min, long max);
std::string env_str(const char *name, const char *fallback);

struct Config {
  size_t max_queue = static_cast<size_t>(env_long("MAX_QUEUE", 100, 1, 100000));
  size_t max_batch = static_cast<size_t>(env_long("MAX_BATCH", 8, 1, 1024));
  size_t threads = static_cast<size_t>(env_long("WORKER_THREADS", 2, 1, 64));
  long timeout_ms = env_long("TIMEOUT_MS", 2000, 1, 600000);
  long work_ms = env_long("WORK_MS", 20, 0, 60000);
  int port = static_cast<int>(env_long("PORT", 8080, 1, 65535));
  std::string model_path = env_str("MODEL_PATH", "/models/model.k3sm");
  std::string model_version = env_str("MODEL_VERSION", "unknown");
  // auto: CUDA when a GPU is visible, otherwise CPU. cuda: fail at start without a GPU. cpu: never touch the GPU.
  std::string device = env_str("DEVICE", "auto");
};
