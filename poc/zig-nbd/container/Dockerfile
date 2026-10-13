# Privileged root mount test for poc/zig-nbd (needs host kernel module: nbd).
FROM ubuntu:24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils git golang erofs-utils kmod util-linux \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.17.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /usr/local \
    && ln -sf "/usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /voila

COPY poc/zig-nbd/container/prove-in-container.sh /usr/local/bin/prove-in-container.sh
RUN chmod +x /usr/local/bin/prove-in-container.sh

ENTRYPOINT ["/usr/local/bin/prove-in-container.sh"]
