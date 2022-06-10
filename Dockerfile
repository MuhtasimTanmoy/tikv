# This Docker image contains a minimal build environment for TiKV
#
# It contains all the tools necessary to reproduce official production builds of TiKV

# We need to use CentOS 7 because many of our users choose this as their deploy machine.
# Since the glibc it uses (2.17) is from 2012 (https://sourceware.org/glibc/wiki/Glibc%20Timeline)
# it is our lowest common denominator in terms of distro support.

# Some commands in this script are structured in order to reduce the number of layers Docker
# generates. Unfortunately Docker is limited to only 125 layers:
# https://github.com/moby/moby/blob/a9507c6f76627fdc092edc542d5a7ef4a6df5eec/layer/layer.go#L50-L53

# We require epel packages, so enable the fedora EPEL repo then install dependencies.
# Install the system dependencies
# Attempt to clean and rebuild the cache to avoid 404s

# To avoid rebuilds we first install all Cargo dependencies


# The prepare image avoid ruining the cache of the builder
FROM centos:7.9.2009 as prepare
WORKDIR /tikv

# This step will always ruin the cache
# There isn't a way with docker to wildcard COPY and preserve the directory structure
COPY . .
RUN mkdir /output
RUN for component in $(find . -type f -name 'Cargo.toml' -exec dirname {} \; | sort -u); do \
     mkdir -p "/output/${component}/src" \
  && touch "/output/${component}/src/lib.rs" \
  && cp "${component}/Cargo.toml" "/output/${component}/Cargo.toml" \
  ; done


FROM centos:7.9.2009 as builder

RUN yum install -y epel-release && \
    yum clean all && \
    yum makecache

RUN yum install -y centos-release-scl && \
    yum install -y \
      devtoolset-8 \
      perl cmake3 && \
    yum clean all

# CentOS gives cmake 3 a weird binary name, so we link it to something more normal
# This is required by many build scripts, including ours.
RUN ln -s /usr/bin/cmake3 /usr/bin/cmake
ENV LIBRARY_PATH /usr/local/lib:$LIBRARY_PATH
ENV LD_LIBRARY_PATH /usr/local/lib:$LD_LIBRARY_PATH

# Install Rustup
RUN curl https://sh.rustup.rs -sSf | sh -s -- --no-modify-path --default-toolchain none -y
ENV PATH /root/.cargo/bin/:$PATH

# Install the Rust toolchain
WORKDIR /tikv
COPY rust-toolchain ./
RUN rustup self update \
  && rustup set profile minimal \
  && rustup default $(cat "rust-toolchain")

# For cargo
COPY scripts ./scripts
COPY etc ./etc
COPY Cargo.lock ./Cargo.lock

COPY --from=prepare /output/ ./

COPY Makefile ./

# Add full source code
COPY cmd/ ./cmd/
COPY components/ ./components/
COPY src/ ./src/

# Build binaries now
RUN source /opt/rh/devtoolset-8/enable && make build_dist_debug

# Export to a clean image
FROM amazonlinux:2022.0.20220504.1
COPY --from=builder /tikv/target/debug/tikv-server /tikv-server
COPY --from=builder /tikv/target/debug/tikv-ctl /tikv-ctl

EXPOSE 20160 20180

ENTRYPOINT ["/tikv-server"]
