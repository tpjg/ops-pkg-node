#!/usr/bin/env bash
# Installs the pinned ops CLI for this host and both pinned Nanos kernels into
# .work/ops-<os>-<machine>, verifying every download against pins.env, and prints that directory.
# Use it with OPS_HOME=<dir> PATH=<dir>/bin:$PATH; ops then reads kernels from
# $OPS_HOME/.ops/<version>[-arm] and never touches ~/.ops.
. "$(dirname "$0")/lib.sh"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)          url=linux/release;          sum=$OPS_SHA256_LINUX_X64 ;;
  Linux/aarch64)         url=linux/aarch64/release;  sum=$OPS_SHA256_LINUX_ARM64 ;;
  Darwin/arm64)          url=darwin/aarch64/release; sum=$OPS_SHA256_DARWIN_ARM64 ;;
  *) die "no pinned ops binary for $(uname -s)/$(uname -m)" ;;
esac

home=$WORK/ops-$(uname -s)-$(uname -m)
bin=$home/bin/ops
mkdir -p "$home/bin" "$home/.ops"
if [[ ! -x $bin ]] || [[ $(sha256 "$bin") != "$sum" ]]; then
  curl -fsSL --retry 3 -o "$bin.tmp" "https://storage.googleapis.com/cli/$url/$OPS_VERSION/ops"
  check_sha256 "$bin.tmp" "$sum"
  chmod 0755 "$bin.tmp" && mv "$bin.tmp" "$bin"
fi

for arch in x64 arm64; do
  set_arch "$arch"
  dir=$home/.ops/$NANOS_DIR
  [[ -f $dir/kernel.img && $(cat "$dir/.sha256" 2>/dev/null) == "$NANOS_SHA256" ]] && continue
  tmp=$WORK/download/$NANOS_TARBALL
  mkdir -p "$WORK/download"
  curl -fsSL --retry 3 -o "$tmp" "https://storage.googleapis.com/nanos/release/$NANOS_VERSION/$NANOS_TARBALL"
  check_sha256 "$tmp" "$NANOS_SHA256"
  rm -rf "$dir" && mkdir -p "$dir"
  tar -xzf "$tmp" -C "$dir"
  echo "$NANOS_SHA256" > "$dir/.sha256"
done
# ops falls back to latest.txt when --nanos-version is not given; keep it on the pin as well.
echo "$NANOS_VERSION" > "$home/.ops/latest.txt"
OPS_HOME=$home "$bin" version >&2
echo "$home"
