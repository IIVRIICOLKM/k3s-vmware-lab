// CUDA backend: the weights are copied to the GPU once; each batch is one host->device copy, one kernel per layer
// and one device->host copy of the logits, on the calling worker thread's own stream.
//
// Kernel: one warp per output neuron. The 32 lanes walk the weight row together (coalesced reads), each keeps a
// partial dot product, and a warp shuffle adds them up. The warp then repeats that for every sample in the batch,
// so a weight row is read from DRAM once per batch and from cache afterwards: that is what batching saves.
//
// The CUDA runtime is linked statically (nvcc default), so the image needs no CUDA libraries; libcuda.so comes from
// the host driver through the NVIDIA container runtime (runtimeClassName: nvidia). Without it, cudaGetDeviceCount
// fails and make_cuda_backend() returns nullptr, so the worker can fall back to the CPU.
#include <cuda_runtime.h>

#include <algorithm>
#include <stdexcept>
#include <string>

#include "backend.h"

namespace {

void check(cudaError_t e, const char *what) {
  if (e != cudaSuccess) throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(e));
}

constexpr int kWarpsPerBlock = 8;

__global__ void linear_kernel(const float *__restrict__ w, const float *__restrict__ b, const float *__restrict__ x,
                              float *__restrict__ y, int in, int out, int batch, int relu) {
  const int neuron = (blockIdx.x * blockDim.x + threadIdx.x) / 32;
  const int lane = threadIdx.x & 31;
  if (neuron >= out) return;  // whole warp leaves together, so the shuffles below stay convergent
  const float *row = w + static_cast<size_t>(neuron) * in;
  for (int s = 0; s < batch; ++s) {
    const float *xs = x + static_cast<size_t>(s) * in;
    float acc = 0.0f;
    for (int i = lane; i < in; i += 32) acc += row[i] * xs[i];
    for (int off = 16; off > 0; off >>= 1) acc += __shfl_down_sync(0xffffffffu, acc, off);
    if (lane == 0) {
      acc += b[neuron];
      y[static_cast<size_t>(s) * out + neuron] = relu ? fmaxf(acc, 0.0f) : acc;
    }
  }
}

struct DeviceLayer {
  int in = 0, out = 0;
  float *w = nullptr, *b = nullptr;
};

class CudaExecutor : public Executor {
 public:
  CudaExecutor(const std::vector<DeviceLayer> &layers, size_t max_batch) : layers_(layers), max_batch_(max_batch) {
    size_t widest = 0;
    for (const DeviceLayer &l : layers_) widest = std::max({widest, static_cast<size_t>(l.in), static_cast<size_t>(l.out)});
    check(cudaStreamCreateWithFlags(&stream_, cudaStreamNonBlocking), "cudaStreamCreate");
    check(cudaMalloc(&buf_[0], max_batch * widest * sizeof(float)), "cudaMalloc");
    check(cudaMalloc(&buf_[1], max_batch * widest * sizeof(float)), "cudaMalloc");
    in_dim_ = layers_.front().in;
    out_dim_ = layers_.back().out;
    // Pinned host buffers make the copies real DMA transfers instead of staged ones.
    check(cudaMallocHost(&host_in_, max_batch * in_dim_ * sizeof(float)), "cudaMallocHost");
    check(cudaMallocHost(&host_out_, max_batch * out_dim_ * sizeof(float)), "cudaMallocHost");
  }

  ~CudaExecutor() override {
    cudaFreeHost(host_out_);
    cudaFreeHost(host_in_);
    cudaFree(buf_[1]);
    cudaFree(buf_[0]);
    cudaStreamDestroy(stream_);
  }

  void run(const std::vector<const std::vector<float> *> &xs, std::vector<std::vector<float>> &logits) override {
    const size_t n = xs.size();
    if (n == 0 || n > max_batch_) throw std::runtime_error("batch size out of range");
    for (size_t s = 0; s < n; ++s) std::copy(xs[s]->begin(), xs[s]->end(), host_in_ + s * in_dim_);
    check(cudaMemcpyAsync(buf_[0], host_in_, n * in_dim_ * sizeof(float), cudaMemcpyHostToDevice, stream_), "copy in");
    int cur = 0;
    for (size_t li = 0; li < layers_.size(); ++li) {
      const DeviceLayer &l = layers_[li];
      const int blocks = (l.out + kWarpsPerBlock - 1) / kWarpsPerBlock;
      linear_kernel<<<blocks, kWarpsPerBlock * 32, 0, stream_>>>(l.w, l.b, buf_[cur], buf_[1 - cur], l.in, l.out,
                                                                 static_cast<int>(n), li + 1 < layers_.size());
      check(cudaGetLastError(), "linear_kernel launch");
      cur = 1 - cur;
    }
    check(cudaMemcpyAsync(host_out_, buf_[cur], n * out_dim_ * sizeof(float), cudaMemcpyDeviceToHost, stream_), "copy out");
    check(cudaStreamSynchronize(stream_), "cudaStreamSynchronize");
    logits.resize(n);
    for (size_t s = 0; s < n; ++s) logits[s].assign(host_out_ + s * out_dim_, host_out_ + (s + 1) * out_dim_);
  }

 private:
  const std::vector<DeviceLayer> &layers_;
  size_t max_batch_;
  size_t in_dim_ = 0, out_dim_ = 0;
  cudaStream_t stream_ = nullptr;
  float *buf_[2] = {nullptr, nullptr};
  float *host_in_ = nullptr, *host_out_ = nullptr;
};

class CudaBackend : public Backend {
 public:
  CudaBackend(const Model &model, std::string name) : name_(std::move(name)) {
    for (const Layer &l : model.layers()) {
      DeviceLayer d;
      d.in = static_cast<int>(l.in);
      d.out = static_cast<int>(l.out);
      check(cudaMalloc(&d.w, l.w.size() * sizeof(float)), "cudaMalloc weights");
      check(cudaMalloc(&d.b, l.b.size() * sizeof(float)), "cudaMalloc bias");
      check(cudaMemcpy(d.w, l.w.data(), l.w.size() * sizeof(float), cudaMemcpyHostToDevice), "copy weights");
      check(cudaMemcpy(d.b, l.b.data(), l.b.size() * sizeof(float), cudaMemcpyHostToDevice), "copy bias");
      layers_.push_back(d);
    }
  }

  ~CudaBackend() override {
    for (DeviceLayer &d : layers_) {
      cudaFree(d.w);
      cudaFree(d.b);
    }
  }

  std::string device() const override { return "cuda"; }
  std::string description() const override { return name_; }
  std::unique_ptr<Executor> executor(size_t max_batch) const override {
    return std::make_unique<CudaExecutor>(layers_, max_batch);
  }

 private:
  std::string name_;
  std::vector<DeviceLayer> layers_;
};

}  // namespace

std::unique_ptr<Backend> make_cuda_backend(const Model &model, std::string &why) {
  int count = 0;
  cudaError_t e = cudaGetDeviceCount(&count);
  if (e != cudaSuccess) {
    why = std::string("no CUDA driver or device: ") + cudaGetErrorString(e);
    return nullptr;
  }
  if (count == 0) {
    why = "no CUDA device visible";
    return nullptr;
  }
  cudaDeviceProp prop{};
  check(cudaGetDeviceProperties(&prop, 0), "cudaGetDeviceProperties");
  check(cudaSetDevice(0), "cudaSetDevice");
  return std::make_unique<CudaBackend>(model, prop.name);
}
