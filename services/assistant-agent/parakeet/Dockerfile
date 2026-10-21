# parakeet.cpp's OpenAI-compatible server (CUDA 12 release build; its own image needs CUDA 13)
FROM debian:trixie-slim AS fetch
ARG PARAKEET_VERSION=v0.6.1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL "https://github.com/mudler/parakeet.cpp/releases/download/${PARAKEET_VERSION}/parakeet-${PARAKEET_VERSION}-bin-linux-cuda12-x64.tar.gz" \
    | tar -xz -C /opt && mv /opt/parakeet-* /opt/parakeet

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /opt/parakeet /opt/parakeet
ENV LD_LIBRARY_PATH=/opt/parakeet
ENTRYPOINT ["/opt/parakeet/parakeet-server"]
