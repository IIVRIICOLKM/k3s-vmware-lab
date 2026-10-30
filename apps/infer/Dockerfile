# Inference worker image (proposal slide 10). Built in the cluster by scripts/image-build.sh (Kaniko).
# cpp-httplib is a single 860 KB header: fetched here at a pinned version and SHA-256 instead of being committed,
# which also keeps the build context under the ConfigMap limit.
FROM docker.io/library/gcc:15.3.0-trixie AS build
ARG HTTPLIB_VERSION=v0.64.0
ARG HTTPLIB_SHA256=805169049e6a6e9ba7729d7e01d14ced825029c88a277586602a6b38df4d5357
WORKDIR /src
RUN curl -fsSL -o httplib.h "https://raw.githubusercontent.com/yhirose/cpp-httplib/${HTTPLIB_VERSION}/httplib.h" \
 && echo "${HTTPLIB_SHA256}  httplib.h" | sha256sum -c -
COPY main.cpp .
# libstdc++/libgcc are linked statically: GCC 15's libstdc++ is newer than the one in Debian trixie.
RUN g++ -std=c++20 -O2 -Wall -Wextra -pthread -static-libstdc++ -static-libgcc -o k3slab-infer main.cpp

FROM docker.io/library/debian:trixie-20261027-slim
COPY --from=build /src/k3slab-infer /usr/local/bin/k3slab-infer
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/k3slab-infer"]
