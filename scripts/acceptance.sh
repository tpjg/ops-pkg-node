#!/usr/bin/env bash
# Acceptance tests for ARCH, run in the test container by scripts/test.sh. Loads
# dist/<package>.tar.gz the way a consumer does (checksum, `ops pkg add`), checks
# `ops pkg contents`, then boots it with test/driver.mjs. The driver runs on the verified
# official Node build for the container's own architecture.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"
[[ $(uname -s) == Linux ]] || die "run this through scripts/test.sh $ARCH"

OPS_HOME=$("$ROOT/scripts/install-ops.sh")
export OPS_HOME PATH=$OPS_HOME/bin:$PATH

host_node=node-v$NODE_VERSION-linux-$(host_arch)
check_sha256 "$WORK/download/$host_node.tar.xz" \
  "$(awk -v f="$host_node.tar.xz" '$2 == f { print $1 }' "$WORK/download/node-v$NODE_VERSION-SHASUMS256.txt")"
# Container-local, not under the bind mount: the tarball has symlinks, which some bind mounts
# (colima's virtiofs) cannot hold.
mkdir -p /opt/host-node
tar -xJf "$WORK/download/$host_node.tar.xz" -C /opt/host-node --strip-components=1
export PATH=/opt/host-node/bin:$PATH
qemu-system-x86_64 --version | head -1

[[ -f $DIST/$PKG_FILE ]] || die "no $DIST/$PKG_FILE; run 'just build $ARCH'"
check_sha256 "$DIST/$PKG_FILE" "$(cut -d' ' -f1 "$DIST/$PKG_FILE.sha256")"

ops pkg add "$DIST/$PKG_FILE" --name "$PKG_NAME" --arch "$OPS_ARCH" >/dev/null
contents=$(ops pkg contents "$PKG_NAME" --local --arch "$OPS_ARCH")
expected=$(printf 'File :/%s\n' BUILDINFO.json LICENSE node package.manifest
           grep -v -e '^#' -e '^[[:space:]]*$' "$ROOT/package/sysroot-$ARCH.txt" | sed 's|^|File :/sysroot|')
diff <(grep '^File' <<<"$contents" | sort) <(sort <<<"$expected") \
  || die "ops pkg contents differs from package/sysroot-$ARCH.txt"
echo "ops pkg contents: $(grep -c '^File' <<<"$contents") files, as listed"

node "$ROOT/test/driver.mjs" --arch "$ARCH" --pkg "$PKG_NAME" --node-version "$NODE_VERSION" \
  --nanos-version "$NANOS_VERSION" --work "$WORK/$ARCH/test"
