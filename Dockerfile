# Adapted from llama.cpp/.devops/cuda.Dockerfile for the bundled P100 source.
ARG UBUNTU_VERSION=22.04
# This needs to generally match the container host's environment.
ARG CUDA_VERSION=12.4.1
ARG GCC_VERSION=11
# Target the CUDA build image
ARG BASE_CUDA_DEV_CONTAINER=docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}

ARG BASE_CUDA_RUN_CONTAINER=docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

ARG NODE_VERSION=24

FROM docker.io/node:$NODE_VERSION AS web

ARG APP_VERSION

WORKDIR /app/tools/ui

COPY llama.cpp/tools/ui/package.json llama.cpp/tools/ui/package-lock.json ./
RUN npm ci

COPY llama.cpp/tools/ui/ ./
RUN LLAMA_BUILD_NUMBER="$APP_VERSION" npm run build

FROM ${BASE_CUDA_DEV_CONTAINER} AS build

ARG GCC_VERSION
# CUDA architecture to build for (defaults to P100)
ARG CUDA_ARCH=60
ARG JOBS=4

RUN apt-get update && \
    apt-get install -y gcc-${GCC_VERSION} g++-${GCC_VERSION} build-essential ca-certificates cmake python3 python3-pip git libssl-dev libgomp1

ENV CC=gcc-${GCC_VERSION} CXX=g++-${GCC_VERSION} CUDAHOSTCXX=g++-${GCC_VERSION}

WORKDIR /app

COPY llama.cpp/ .

COPY --from=web /app/tools/ui/dist tools/ui/dist

RUN cmake -B build -DGGML_NATIVE=OFF -DGGML_CUDA=ON -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON -DLLAMA_BUILD_TESTS=OFF \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined . \
    && cmake --build build --config Release --parallel "${JOBS}"

RUN mkdir -p /app/lib && \
    find build -name "*.so*" -exec cp -P {} /app/lib \;

# Server, CLI, and benchmark runtime.
FROM ${BASE_CUDA_RUN_CONTAINER} AS runtime

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="p100-llama-cpp-docker" \
      org.opencontainers.image.description="Patched llama.cpp for Tesla P100 GPUs" \
      org.opencontainers.image.source="https://github.com/at527/p100-llama-cpp-docker"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg libgomp1 libssl3 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/lib/ /app/
COPY --from=build /app/build/bin/llama-server /app/build/bin/llama-cli /app/build/bin/llama-bench /app/
COPY LICENSE /usr/local/share/licenses/p100-llama-cpp/LICENSE
COPY llama.cpp/LICENSE /usr/local/share/licenses/llama.cpp/LICENSE

ENV PATH=/app:$PATH \
    LD_LIBRARY_PATH=/app:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    LLAMA_ARG_HOST=0.0.0.0
WORKDIR /app
EXPOSE 8080
HEALTHCHECK --start-period=5m CMD ["curl", "-f", "http://localhost:8080/health"]
ENTRYPOINT ["/app/llama-server"]
