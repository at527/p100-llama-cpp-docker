# syntax=docker/dockerfile:1
FROM node:24-bookworm-slim AS web
WORKDIR /ui
COPY llama.cpp/tools/ui/package.json llama.cpp/tools/ui/package-lock.json ./
RUN npm ci
COPY llama.cpp/tools/ui/ ./
RUN npm run build && test -s dist/index.html

FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS build
ARG CUDA_ARCH=60
ARG JOBS=4
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential cmake ninja-build libssl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY llama.cpp/ ./
COPY --from=web /ui/dist/ ./tools/ui/dist/
RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=ON \
        -DGGML_BACKEND_DIR=/usr/local/lib/llama \
        -DGGML_CPU_ALL_VARIANTS=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_APP=OFF \
        -DLLAMA_BUILD_UI=OFF \
        -DLLAMA_USE_PREBUILT_UI=OFF \
    && cmake --build build --parallel "${JOBS}" --target llama-server llama-cli llama-bench \
    && mkdir -p /out/bin /out/lib \
    && cp build/bin/llama-server build/bin/llama-cli build/bin/llama-bench /out/bin/ \
    && cp -a build/bin/*.so* /out/lib/

FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04 AS runtime
LABEL org.opencontainers.image.title="p100-llama-cpp-docker" \
      org.opencontainers.image.description="Patched llama.cpp for Tesla P100 GPUs" \
      org.opencontainers.image.source="https://github.com/at527/p100-llama-cpp-docker"
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libgomp1 libssl3 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bin/ /usr/local/bin/
COPY --from=build /out/lib/ /usr/local/lib/llama/
COPY LICENSE /usr/local/share/licenses/p100-llama-cpp/LICENSE
COPY llama.cpp/LICENSE /usr/local/share/licenses/llama.cpp/LICENSE
ENV LD_LIBRARY_PATH=/usr/local/lib/llama:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    LLAMA_ARG_HOST=0.0.0.0 \
    LLAMA_ARG_PORT=8080
WORKDIR /models
EXPOSE 8080
ENTRYPOINT ["llama-server"]
