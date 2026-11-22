#include "model.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>

Model Model::load(const std::string &path) {
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

uint64_t Model::macs() const {
  uint64_t n = 0;
  for (const Layer &l : layers_) n += static_cast<uint64_t>(l.out) * l.in;
  return n;
}

std::vector<float> Model::logits(const std::vector<float> &x) const {
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
  return cur;
}

void softmax(std::vector<float> &v) {
  float mx = *std::max_element(v.begin(), v.end()), sum = 0.0f;
  for (float &x : v) sum += (x = std::exp(x - mx));
  for (float &x : v) x /= sum;
}
