// Stand-in for backend_cuda.cu when building without the CUDA toolkit (`make CUDA=0`, e.g. a laptop without nvcc).
// The image always builds the real CUDA backend.
#include "backend.h"

std::unique_ptr<Backend> make_cuda_backend(const Model &, std::string &why) {
  why = "built without CUDA";
  return nullptr;
}
