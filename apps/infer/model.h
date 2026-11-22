// The classifier exported by apps/train/train.py (export_raw): Linear layers with ReLU in between, plain float32
// weights in the K3SM v1 file, so the worker needs no ML runtime.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct Layer {
  uint32_t out = 0, in = 0;
  std::vector<float> w, b;  // w is row-major [out][in]
};

class Model {
 public:
  static Model load(const std::string &path);

  size_t input_dim() const { return layers_.front().in; }
  size_t output_dim() const { return layers_.back().out; }
  const std::vector<Layer> &layers() const { return layers_; }
  // Multiply-accumulates per sample (for the startup log: how heavy one request is).
  uint64_t macs() const;

  // CPU forward pass for one sample; returns logits (no softmax).
  std::vector<float> logits(const std::vector<float> &x) const;

 private:
  std::vector<Layer> layers_;
};

// In-place softmax over one sample's logits.
void softmax(std::vector<float> &v);
