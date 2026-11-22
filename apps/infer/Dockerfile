# Inference worker image (proposal slide 10). Built in the cluster by scripts/image-build.sh (Kaniko).
# Stage 1 fetches cpp-httplib (a single 860 KB header) at a pinned version and SHA-256 instead of committing it,
# which also keeps the build context under the ConfigMap limit.
# Stage 2 compiles with the CUDA 13.0 toolkit (the newest the host driver 580 supports) for the RTX 3090 (sm_86).
# The CUDA runtime is linked statically, so the runtime image is plain Debian: the NVIDIA container runtime mounts
# the host driver (libcuda.so) into GPU pods, and without it the worker falls back to the CPU (DEVICE=auto).
FROM docker.io/library/gcc:15.3.0-trixie AS fetch
ARG HTTPLIB_VERSION=v0.64.0
ARG HTTPLIB_SHA256=805169049e6a6e9ba7729d7e01d14ced825029c88a277586602a6b38df4d5357
WORKDIR /src
RUN curl -fsSL -o httplib.h "https://raw.githubusercontent.com/yhirose/cpp-httplib/${HTTPLIB_VERSION}/httplib.h" \
 && echo "${HTTPLIB_SHA256}  httplib.h" | sha256sum -c -

FROM docker.io/nvidia/cuda:13.0.3-devel-ubuntu24.04 AS build
WORKDIR /src
COPY --from=fetch /src/httplib.h .
COPY Makefile *.h *.cpp *.cu ./
# The devel image ships nvcc and g++; make is installed only if it is missing.
RUN (command -v make >/dev/null || (apt-get update && apt-get install -y --no-install-recommends make \
      && rm -rf /var/lib/apt/lists/*)) \
 && make -j"$(nproc)" CUDA=1

FROM docker.io/library/debian:trixie-20261027-slim
COPY --from=build /src/k3slab-infer /usr/local/bin/k3slab-infer
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/k3slab-infer"]
