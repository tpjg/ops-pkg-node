# shellcheck shell=bash disable=SC2034  # variables here are used by the scripts that source this
# Sourced by the other scripts. Sets pins, the Node version and per-architecture names.
# ARCH uses Node's naming (x64 | arm64); the other tools each name architectures differently.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$ROOT/.work
DIST=$ROOT/dist
# shellcheck source=../pins.env
. "$ROOT/pins.env"
NODE_VERSION=$(tr -d '[:space:]' < "$ROOT/NODE_VERSION")
PKG_NAME=node_$NODE_VERSION

die() { echo "error: $*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# check_sha256 FILE EXPECTED
check_sha256() {
  local got; got=$(sha256 "$1")
  [[ $got == "$2" ]] || die "sha256 mismatch for $1: expected $2, got $got"
}

set_arch() {
  ARCH=${1:-}
  case $ARCH in
    x64)   OPS_ARCH=amd64; DOCKER_PLATFORM=linux/amd64; TRIPLET=x86_64-linux-gnu;  ELF_MACHINE='Advanced Micro Devices X86-64'
           DEBIAN_DIGEST=$DEBIAN_DIGEST_X64;   NANOS_SHA256=$NANOS_SHA256_X64;   NANOS_DIR=$NANOS_VERSION
           NANOS_TARBALL=nanos-release-linux-$NANOS_VERSION.tar.gz ;;
    arm64) OPS_ARCH=arm64; DOCKER_PLATFORM=linux/arm64; TRIPLET=aarch64-linux-gnu; ELF_MACHINE='AArch64'
           DEBIAN_DIGEST=$DEBIAN_DIGEST_ARM64; NANOS_SHA256=$NANOS_SHA256_ARM64; NANOS_DIR=$NANOS_VERSION-arm
           NANOS_TARBALL=nanos-release-linux-$NANOS_VERSION-virt.tar.gz ;;
    *) die "ARCH must be x64 or arm64, got '$ARCH'" ;;
  esac
  NODE_DIST=node-v$NODE_VERSION-linux-$ARCH
  PKG_FILE=${PKG_NAME}_linux-$ARCH.tar.gz
}

# The host's architecture in Node's naming.
host_arch() {
  case "$(uname -m)" in
    x86_64) echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported host architecture $(uname -m)" ;;
  esac
}

# build_image TAG DIR BUILD_ARG...
build_image() {
  local tag=$1 dir=$2 log; shift 2
  if ! log=$(docker build -q -t "$tag" "${@/#/--build-arg=}" "$dir" 2>&1); then
    echo "$log" >&2
    die "building $tag failed"
  fi
}

# Containers run as the calling user, so files they write under the repo stay the user's.
DOCKER_USER=(--user "$(id -u):$(id -g)" -e HOME=/tmp)

# Runs a command in the tools container (tools/Dockerfile), with the repo mounted at /src.
in_tools() {
  local tag=ops-pkg-node-tools:$DEBIAN_SNAPSHOT
  build_image "$tag" "$ROOT/tools" DEBIAN_INDEX_DIGEST="$DEBIAN_INDEX_DIGEST" DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT"
  docker run --rm "${DOCKER_USER[@]}" -v "$ROOT:/src" -w /src "$tag" "$@"
}

# Runs a command in the test container (test/Dockerfile), passing /dev/kvm through when usable.
in_test() {
  local tag=ops-pkg-node-test:$UBUNTU_SNAPSHOT kvm=()
  build_image "$tag" "$ROOT/test" UBUNTU_INDEX_DIGEST="$UBUNTU_INDEX_DIGEST" UBUNTU_SNAPSHOT="$UBUNTU_SNAPSHOT"
  [[ -w /dev/kvm ]] && kvm=(--device /dev/kvm)
  docker run --rm "${DOCKER_USER[@]}" ${kvm[@]+"${kvm[@]}"} -v "$ROOT:/src" -w /src "$tag" "$@"
}
