FROM ubuntu:24.04

RUN dpkg --add-architecture i386 && \
    apt-get update && apt-get install -y \
    binutils gdb strace file \
    libc6:i386 libgcc-s1:i386 \
    && rm -rf /var/lib/apt/lists/*

COPY red-view /usr/local/bin/red-view
RUN chmod +x /usr/local/bin/red-view

WORKDIR /workspace
