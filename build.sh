#!/bin/bash
set -ex

# x86_64-unknown-linux-musl
# docker build -t cookiemagic/rust-musl-cross:amd64-musl .
# aarch64-unknown-linux-musl
docker build --build-arg TARGET=aarch64-unknown-linux-musl --build-arg OPENSSL_ARCH=linux-aarch64 --build-arg RUST_MUSL_MAKE_CONFIG=config.mak -t cookiemagic/rust-musl-cross:arm64-musl .
