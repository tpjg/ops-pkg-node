#!/usr/bin/env bash
# verify-node.sh ARCH DIR: verifies the Node.js download in DIR. Exits non-zero unless
#   1. the release keyring has the sha256 pinned for NODE_RELEASE_KEYS_COMMIT,
#   2. SHASUMS256.txt.sig is a valid signature over SHASUMS256.txt by a key in that keyring,
#   3. the tarball's sha256 is the one SHASUMS256.txt lists for it.
# scripts/test-verify.sh checks that each of these failures stops the build.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"
dir=${2:?usage: verify-node.sh ARCH DIR}
keyring=$dir/release-keys-$NODE_RELEASE_KEYS_COMMIT.kbx
sums=$dir/node-v$NODE_VERSION-SHASUMS256.txt
tarball=$dir/$NODE_DIST.tar.xz

check_sha256 "$keyring" "$NODE_RELEASE_KEYRING_SHA256"
if ! gpgv --keyring "$keyring" "$sums.sig" "$sums" > "$sums.gpgv" 2>&1; then
  cat "$sums.gpgv" >&2
  die "SHASUMS256.txt signature did not verify"
fi
cat "$sums.gpgv"
expected=$(awk -v f="$NODE_DIST.tar.xz" '$2 == f { print $1 }' "$sums")
[[ $expected =~ ^[0-9a-f]{64}$ ]] || die "$NODE_DIST.tar.xz is not listed in SHASUMS256.txt"
check_sha256 "$tarball" "$expected"
echo "verified $NODE_DIST.tar.xz sha256:$expected"
