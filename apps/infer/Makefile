# Builds the inference worker. The image build (Dockerfile) runs `make`; `make CUDA=0` builds a CPU-only binary
# without the CUDA toolkit (backend_nocuda.cpp instead of backend_cuda.cu), for a quick local check.
# httplib.h (cpp-httplib) is not in the repo: the Dockerfile downloads it at a pinned version and SHA-256.
CXX ?= g++
NVCC ?= nvcc
CUDA ?= 1
# sm_86 = RTX 3090 (gpu-host). compute_86 PTX is embedded too, so a newer GPU can JIT-compile it.
CUDA_ARCH ?= -gencode arch=compute_86,code=sm_86 -gencode arch=compute_86,code=compute_86
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -pthread
# libstdc++/libgcc are linked statically: the build image's libstdc++ may be newer than the runtime image's.
LDFLAGS ?= -pthread -static-libstdc++ -static-libgcc

OBJS = main.o config.o model.o util.o metrics.o worker.o backend_cpu.o

ifeq ($(CUDA),1)
OBJS += backend_cuda.o
CUDA_HOME ?= /usr/local/cuda
# The CUDA runtime is linked statically (libcudart_static); only the driver (libcuda.so) is needed at run time.
LINK = $(CXX) -o $@ $^ -L$(CUDA_HOME)/lib64 -lcudart_static -ldl -lrt $(LDFLAGS)
else
OBJS += backend_nocuda.o
LINK = $(CXX) $(LDFLAGS) -o $@ $^
endif

k3slab-infer: $(OBJS)
	$(LINK)

%.o: %.cpp *.h
	$(CXX) $(CXXFLAGS) -c -o $@ $<

backend_cuda.o: backend_cuda.cu backend.h model.h
	$(NVCC) -std=c++20 -O2 $(CUDA_ARCH) -c -o $@ $<

clean:
	rm -f *.o k3slab-infer

.PHONY: clean
