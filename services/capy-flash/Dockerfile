# capy-flash from its prebuilt release (Ubuntu 26.04, sm_120a): the release's runtime libraries, the release itself
# checked against its SHA-256, run as an unprivileged user. Version and checksum are updated by hand (README.txt).
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

ARG CAPY_VERSION=v0.10.0
ARG CAPY_SHA256=eed9c8c2ebc99bc9a7a88a3f671b51ca7529c3ed6f685906fd6a23c788a2b19e
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates curl libavcodec62 libavformat62 libavutil60 libcurl4t64 libswscale9 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    tarball=capy-flash-${CAPY_VERSION}-linux-x86_64-sm120a-ubuntu26.04.tar.gz; \
    curl -fsSL -o /tmp/$tarball "https://github.com/ValerioDolci/capy-flash/releases/download/${CAPY_VERSION}/$tarball"; \
    echo "${CAPY_SHA256}  /tmp/$tarball" | sha256sum -c -; \
    mkdir /opt/capy-flash; \
    tar -xzf /tmp/$tarball -C /opt/capy-flash --strip-components 1; \
    rm /tmp/$tarball; \
    cd /opt/capy-flash && sha256sum --quiet -c SHA256SUMS

# the base image's own unprivileged user (UID 1000)
USER ubuntu
ENV LD_LIBRARY_PATH=/opt/capy-flash/lib \
    PATH=/opt/capy-flash/bin:$PATH \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility
EXPOSE 8080
ENTRYPOINT ["ninfer-serve"]
