FROM ubuntu:20.04

ARG TARGET=x86_64-unknown-linux-musl
ARG OPENSSL_ARCH=linux-x86_64
ARG RUST_MUSL_MAKE_VER=0.9.9
ARG RUST_MUSL_MAKE_CONFIG=config.mak

ENV DEBIAN_FRONTEND=noninteractive
ENV RUST_MUSL_CROSS_TARGET=$TARGET

# Make sure we have basic dev tools for building C libraries.  Our goal
# here is to support the musl-libc builds and Cargo builds needed for a
# large selection of the most popular crates.
#
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    cmake \
    curl \
    file \
    git \
    sudo \
    xutils-dev \
    libpq-dev \
    libssl-dev \
    unzip \
    ca-certificates \
    python3 \
    python3-pip \
    && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install cross-signed Let's Encrypt R3 CA certificate
COPY lets-encrypt-r3-cross-signed.crt /usr/local/share/ca-certificates
RUN update-ca-certificates

COPY $RUST_MUSL_MAKE_CONFIG /tmp/config.mak
RUN cd /tmp && curl -Lsq -o musl-cross-make.zip https://github.com/richfelker/musl-cross-make/archive/v$RUST_MUSL_MAKE_VER.zip && \
    unzip -q musl-cross-make.zip && \
    rm musl-cross-make.zip && \
    mv musl-cross-make-$RUST_MUSL_MAKE_VER musl-cross-make && \
    cp /tmp/config.mak /tmp/musl-cross-make/config.mak && \
    cd /tmp/musl-cross-make && \
    TARGET=$TARGET make -j$(nproc) install > /tmp/musl-cross-make.log && \
    ln -s /usr/local/musl/bin/$TARGET-strip /usr/local/musl/bin/musl-strip && \
    cd /tmp && \
    rm -rf /tmp/musl-cross-make /tmp/musl-cross-make.log

RUN mkdir -p /home/rust/libs /home/rust/src

# Set up our path with all our binary directories, including those for the
# musl-gcc toolchain and for our Rust toolchain.
ENV PATH=/root/.cargo/bin:/usr/local/musl/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV TARGET_CC=$TARGET-gcc
ENV TARGET_CXX=$TARGET-g++
ENV TARGET_HOME=/usr/local/musl/$TARGET
ENV TARGET_C_INCLUDE_PATH=$TARGET_HOME/include/

# We'll build our libraries in subdirectories of /home/rust/libs.  Please
# clean up when you're done.
WORKDIR /home/rust/libs

# Build a static library version of OpenSSL using musl-libc.  This is
# needed by the popular Rust `hyper` crate.
RUN export CC=$TARGET_CC && \
    export C_INCLUDE_PATH=$TARGET_C_INCLUDE_PATH && \
    echo "Building zlib" && \
    VERS=1.2.12 && \
    cd /home/rust/libs && \
    curl -sqLO https://zlib.net/zlib-$VERS.tar.gz && \
    tar xzf zlib-$VERS.tar.gz && cd zlib-$VERS && \
    ./configure --static --archs="-fPIC" --prefix=$TARGET_HOME && \
    make && sudo make install -j$(nproc) && \
    cd .. && rm -rf zlib-$VERS.tar.gz zlib-$VERS checksums.txt

RUN export CC=$TARGET_CC && \
    export C_INCLUDE_PATH=$TARGET_C_INCLUDE_PATH && \
    export LD=$TARGET-ld && \
    echo "Building OpenSSL" && \
    VERS=1.1.1i && \
    curl -sqO https://www.openssl.org/source/openssl-$VERS.tar.gz && \
    tar xzf openssl-$VERS.tar.gz && cd openssl-$VERS && \
    ./Configure $OPENSSL_ARCH no-shared no-zlib no-tests -fPIC --prefix=$TARGET_HOME && \
    make -j$(nproc) && make install && \
    cd .. && rm -rf openssl-$VERS.tar.gz openssl-$VERS checksums.txt


RUN export CC=$TARGET_CC && \
    export C_INCLUDE_PATH=$TARGET_C_INCLUDE_PATH && \
    export LD=$TARGET-ld && \
    echo "Building libpq" && \
    VERS=11.11 && \
    cd /tmp && \
    curl -fLO "https://ftp.postgresql.org/pub/source/v$VERS/postgresql-$VERS.tar.gz" && \
    tar xzf "postgresql-$VERS.tar.gz" && cd "postgresql-$VERS" && \
    ./configure --with-openssl --without-readline --host=$TARGET --prefix=$TARGET_HOME && \
    cd src/interfaces/libpq && make -j$(nproc) all-static-lib && make install-lib-static && \
    make -j$(nproc) && make install && \
    cd ../../bin/pg_config && make -j$(nproc) && make install && \
    rm -r /tmp/*


ENV OPENSSL_DIR=$TARGET_HOME/ \
    OPENSSL_INCLUDE_DIR=$TARGET_HOME/include/ \
    DEP_OPENSSL_INCLUDE=$TARGET_HOME/include/ \
    OPENSSL_LIB_DIR=$TARGET_HOME/lib/ \
    OPENSSL_STATIC=1 \
    PQ_LIB_STATIC=1 \
    PQ_LIB_DIR=$TARGET_HOME/lib \
    PG_CONFIG=$TARGET_HOME/bin/pg_config \
    PKG_CONFIG_ALLOW_CROSS=true \
    PKG_CONFIG_ALL_STATIC=true \
    LIBZ_SYS_STATIC=1

# The Rust toolchain to use when building our image
ARG TOOLCHAIN=stable
# Install our Rust toolchain and the `musl` target.  We patch the
# command-line we pass to the installer so that it won't attempt to
# interact with the user or fool around with TTYs.  We also set the default
# `--target` to musl so that our users don't need to keep overriding it
# manually.
# Chmod 755 is set for root directory to allow access execute binaries in /root/.cargo/bin (azure piplines create own user).
#
# Remove docs and more stuff not needed in this images to make them smaller
RUN chmod 755 /root/ && \
    curl https://sh.rustup.rs -sqSf | \
    sh -s -- -y --profile minimal --default-toolchain $TOOLCHAIN && \
    rustup target add $TARGET && \
    rustup component add --toolchain $TOOLCHAIN rustfmt clippy && \
    rm -rf /root/.rustup/toolchains/$TOOLCHAIN-$(uname -m)-unknown-linux-gnu/share/

RUN echo "[target.$TARGET]\nlinker = \"$TARGET-gcc\"\n" > /root/.cargo/config

# Build std sysroot for targets that doesn't have official std release
ADD Xargo.toml /tmp/Xargo.toml
ADD build-std.sh .
RUN bash build-std.sh

ENV RUSTUP_HOME=/root/.rustup
ENV CARGO_HOME=/root/.cargo
ENV CARGO_BUILD_TARGET=$TARGET

ENV CFLAGS_armv7_unknown_linux_musleabihf='-mfpu=vfpv3-d16'

# Expect our source code to live in /home/rust/src
WORKDIR /home/rust/src
