#!/usr/bin/env bash
# Assembles the ops package for ARCH from the verified Node tarball (scripts/fetch-node.sh) and
# the exported target-arch rootfs (scripts/export-sysroot.sh). Runs in the tools container.
#
# Package layout (what `ops pkg from-run` produces, and what `ops pkg add` expects at the
# archive root):
#   package.manifest   ops config subset: Program, Args, Version, ...
#   node               the program; ops adds it to the image as /node
#   sysroot/           copied into the image root
#   BUILDINFO.json     inputs and per-file sha256; not part of the image
#   LICENSE            Node.js license; not part of the image
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"

tarball=$WORK/download/$NODE_DIST.tar.xz
rootfs_tar=$WORK/$ARCH/rootfs.tar
list=$ROOT/package/sysroot-$ARCH.txt
[[ -f $tarball && -f $rootfs_tar ]] || die "run 'just build $ARCH' (needs fetch and export-sysroot first)"
# fetch-node.sh verified the tarball; re-check it against the signed SHASUMS256.txt it trusted.
check_sha256 "$tarball" "$(awk -v f="$NODE_DIST.tar.xz" '$2 == f { print $1 }' "$WORK/download/node-v$NODE_VERSION-SHASUMS256.txt")"

stage=$WORK/$ARCH/stage
rootfs=$(mktemp -d)   # container-local; the image has read-only dirs that a bind mount cannot hold
pkg=$stage/$PKG_NAME
rm -rf "$stage"
mkdir -p "$pkg/sysroot" "$rootfs" "$DIST"

tar -xJf "$tarball" -C "$stage" "$NODE_DIST/bin/node" "$NODE_DIST/LICENSE"
install -m 0755 "$stage/$NODE_DIST/bin/node" "$pkg/node"
install -m 0644 "$stage/$NODE_DIST/LICENSE" "$pkg/LICENSE"
epoch=$(stat -c %Y "$stage/$NODE_DIST/bin/node")

tar -xf "$rootfs_tar" -C "$rootfs" --no-same-owner --exclude=dev

# Resolves an absolute path inside $rootfs one component at a time, following symlinks with
# absolute targets relative to the image root, so nothing is read from this container's own /.
resolve() {
  local rest=${1#/} out='' part target hops=0
  while [[ -n $rest ]]; do
    part=${rest%%/*}
    if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=; fi
    case $part in ''|.) continue ;; ..) out=${out%/*}; continue ;; esac
    if [[ -L $rootfs$out/$part ]]; then
      (( ++hops <= 32 )) || die "too many symlinks resolving $1"
      target=$(readlink "$rootfs$out/$part")
      [[ $target == /* ]] && out=
      rest=${target#/}${rest:+/$rest}
    else
      out=$out/$part
    fi
  done
  [[ -f $rootfs$out ]] || die "$1 does not exist in the $DOCKER_PLATFORM image"
  printf '%s' "$rootfs$out"
}

mapfile -t files < <(grep -v -e '^#' -e '^[[:space:]]*$' "$list")
for f in "${files[@]}"; do
  src=$(resolve "$f")
  install -D -m 0755 "$src" "$pkg/sysroot$f"
done

# Closure check: every ELF has the target machine type, and the NEEDED libraries of bin/node
# and of every listed file resolve inside the sysroot via the loader's system search path.
interp=$(readelf -l "$pkg/node" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
[[ -f $pkg/sysroot$interp ]] || die "interpreter $interp is not in the sysroot"
for elf in "$pkg/node" "${files[@]/#/$pkg/sysroot}"; do
  machine=$(readelf -h "$elf" | sed -n 's/^ *Machine: *//p')
  [[ $machine == "$ELF_MACHINE" ]] || die "$elf is '$machine', expected '$ELF_MACHINE'"
  for lib in $(readelf -d "$elf" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    [[ $lib == "$(basename "$interp")" ]] && continue   # the loader satisfies its own soname
    found=
    for dir in /lib/$TRIPLET /usr/lib/$TRIPLET /lib /usr/lib; do
      [[ -f $pkg/sysroot$dir/$lib ]] && { found=1; break; }
    done
    [[ -n $found ]] || die "${elf#"$pkg/"} needs $lib, which is not in $(basename "$list")"
  done
done
glibc=$(strings "$pkg/sysroot/lib/$TRIPLET/libc.so.6" | sed -n 's/^GNU C Library .* version \([0-9.]*\)\..*/\1/p' | head -1)

jq -n --arg v "$NODE_VERSION" --arg prog "$PKG_NAME/node" --arg arch "$ARCH" --arg glibc "$glibc" '{
  Program: $prog,
  Args: ["node"],
  Version: $v,
  Language: "javascript",
  Description: "Node.js \($v) (official linux-\($arch) binary) with glibc \($glibc) from debian:trixie-slim"
}' > "$pkg/package.manifest"

( cd "$pkg" && find . -type f ! -name BUILDINFO.json -printf '%P\n' | LC_ALL=C sort | while read -r f; do
    jq -n --arg path "$f" --arg sha256 "$(sha256sum "$f" | cut -d' ' -f1)" --argjson size "$(stat -c %s "$f")" '{$path, $sha256, $size}'
  done ) | jq -s \
  --arg node "$NODE_VERSION" --arg arch "$ARCH" --arg tarball "$NODE_DIST.tar.xz" \
  --arg tarball_sha256 "$(sha256 "$tarball")" --arg keys "$NODE_RELEASE_KEYS_COMMIT" \
  --arg image "debian@$DEBIAN_DIGEST" --arg platform "$DOCKER_PLATFORM" --arg glibc "$glibc" \
  --arg ops "$OPS_VERSION" --arg nanos "$NANOS_VERSION" '{
    node: {version: $node, arch: $arch, tarball: $tarball, sha256: $tarball_sha256, release_keys_commit: $keys},
    sysroot: {image: $image, platform: $platform, glibc: $glibc},
    tested_with: {ops: $ops, nanos: $nanos},
    files: .
  }' > "$pkg/BUILDINFO.json"

# Deterministic archive: sorted entries, fixed mtime/owner/mode, gzip without name or timestamp.
out=$DIST/$PKG_FILE
( cd "$pkg" && LC_ALL=C tar --sort=name --format=gnu --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go+rX,go-w' -cf - package.manifest node sysroot BUILDINFO.json LICENSE ) | gzip -9n > "$out"
( cd "$DIST" && sha256sum "$PKG_FILE" > "$PKG_FILE.sha256" )
rm -rf "$rootfs"
echo "built $out ($(du -h "$out" | cut -f1), unpacked $(du -sh "$pkg" | cut -f1)), glibc $glibc"
cat "$DIST/$PKG_FILE.sha256"
