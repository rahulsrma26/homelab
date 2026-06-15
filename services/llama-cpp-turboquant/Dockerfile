FROM nvidia/cuda:13.3.0-cudnn-devel-ubuntu24.04

RUN apt-get update && apt-get install -y \
    git cmake build-essential ninja-build libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth=1 https://github.com/TheTom/llama-cpp-turboquant.git .
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/lib/libcuda.so.1 && ldconfig && \
    cmake -B build -DGGML_CUDA=ON && cmake --build build -j
RUN cp build/bin/llama-server /usr/local/bin/llama-server

EXPOSE 8000
EXPOSE 8123
EXPOSE 8080
