# apt-cacher-ng from Debian itself (the third-party images are years old)
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends apt-cacher-ng wget ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
EXPOSE 3142
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
