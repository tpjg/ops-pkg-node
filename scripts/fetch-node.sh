#!/usr/bin/env bash
# Downloads the official Node.js tarball for ARCH plus SHASUMS256.txt, its signature and the
# pinned release keyring into .work/download, then verifies them with scripts/verify-node.sh.
# Runs in the tools container.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"
[[ $NODE_VERSION =~ ^24\.[0-9]+\.[0-9]+$ ]] || die "NODE_VERSION must be a 24.x.y release, got '$NODE_VERSION'"

dl=$WORK/download
mkdir -p "$dl"
base=https://nodejs.org/dist/v$NODE_VERSION
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

keyring=$dl/release-keys-$NODE_RELEASE_KEYS_COMMIT.kbx
[[ -f $keyring ]] || fetch "https://raw.githubusercontent.com/nodejs/release-keys/$NODE_RELEASE_KEYS_COMMIT/gpg-only-active-keys/pubring.kbx" "$keyring"
fetch "$base/SHASUMS256.txt" "$dl/node-v$NODE_VERSION-SHASUMS256.txt"
fetch "$base/SHASUMS256.txt.sig" "$dl/node-v$NODE_VERSION-SHASUMS256.txt.sig"
# Re-download the tarball only if the cached copy does not match the fresh SHASUMS256.txt;
# verify-node.sh checks everything again either way.
listed=$(awk -v f="$NODE_DIST.tar.xz" '$2 == f { print $1 }' "$dl/node-v$NODE_VERSION-SHASUMS256.txt")
if [[ ! -f $dl/$NODE_DIST.tar.xz ]] || [[ $(sha256 "$dl/$NODE_DIST.tar.xz") != "$listed" ]]; then
  fetch "$base/$NODE_DIST.tar.xz" "$dl/$NODE_DIST.tar.xz"
fi
"$ROOT/scripts/verify-node.sh" "$ARCH" "$dl"
