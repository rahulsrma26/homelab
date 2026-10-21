# audio.cpp's OpenAI-compatible server (CUDA 12.8 release build + its runtime and NCCL)
FROM debian:trixie-slim AS fetch
ARG AUDIOCPP_VERSION=v0.9.2-drama3-base-small
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl python3-pip unzip \
 && mkdir -p /opt/audiocpp && cd /opt/audiocpp \
 && base="https://github.com/0xShug0/audio.cpp/releases/download/${AUDIOCPP_VERSION}" \
 && curl -fsSL "$base/audio-${AUDIOCPP_VERSION}-bin-ubuntu-x64-cuda12.8-colab.tar.gz" | tar -xz \
 && curl -fsSL "$base/audio-${AUDIOCPP_VERSION}-cudart-ubuntu-x64-cuda12.8.tar.gz" | tar -xz \
 && pip download --no-deps -d /tmp/nccl nvidia-nccl-cu12 \
 && unzip -q -j /tmp/nccl/*.whl 'nvidia/nccl/lib/libnccl.so.2' -d /opt/audiocpp

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /opt/audiocpp /opt/audiocpp
COPY entrypoint.sh /entrypoint.sh
ENV LD_LIBRARY_PATH=/opt/audiocpp
ENTRYPOINT ["/entrypoint.sh"]
