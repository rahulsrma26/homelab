# parakeet.cpp's OpenAI-compatible server from its release builds: cuda12-x64 (its own image
# needs CUDA 13), cpu-x64 or vulkan-x64 (iGPU; adds the Vulkan loader and Mesa drivers)
FROM debian:trixie-slim AS fetch
ARG PARAKEET_VERSION=v0.6.1
ARG PARAKEET_BUILD=cuda12-x64
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL "https://github.com/mudler/parakeet.cpp/releases/download/${PARAKEET_VERSION}/parakeet-${PARAKEET_VERSION}-bin-linux-${PARAKEET_BUILD}.tar.gz" \
    | tar -xz -C /opt && mv /opt/parakeet-* /opt/parakeet

FROM debian:trixie-slim
ARG PARAKEET_BUILD=cuda12-x64
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 curl ca-certificates \
    $([ "$PARAKEET_BUILD" = vulkan-x64 ] && echo libvulkan1 mesa-vulkan-drivers) \
 && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /opt/parakeet /opt/parakeet
ENV LD_LIBRARY_PATH=/opt/parakeet
ENTRYPOINT ["/opt/parakeet/parakeet-server"]
