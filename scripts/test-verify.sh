#!/usr/bin/env bash
# Negative tests for scripts/verify-node.sh: each tampered copy of a verified download must be
# rejected. Needs a verified download in .work/download (scripts/fetch-node.sh ARCH first).
# Runs in the tools container.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"
src=$WORK/download
"$ROOT/scripts/verify-node.sh" "$ARCH" "$src" >/dev/null || die "the untampered download does not verify"

fails=0
expect_rejected() {
  local name=$1 tamper=$2 case
  case=$(mktemp -d)
  cp "$src/release-keys-$NODE_RELEASE_KEYS_COMMIT.kbx" "$src/node-v$NODE_VERSION-SHASUMS256.txt"* "$src/$NODE_DIST.tar.xz" "$case/"
  (cd "$case" && eval "$tamper")
  if "$ROOT/scripts/verify-node.sh" "$ARCH" "$case" >/dev/null 2>&1; then
    echo "FAIL $name: accepted"; fails=$((fails + 1))
  else
    echo "ok   $name: rejected"
  fi
  rm -rf "$case"
}
sums=node-v$NODE_VERSION-SHASUMS256.txt
expect_rejected "edited SHASUMS256.txt"   "sed -i '1s/^./0/' $sums"
expect_rejected "truncated signature"     "head -c 40 $sums.sig > s && mv s $sums.sig"
expect_rejected "tarball with overwritten bytes" "printf tampered | dd of=$NODE_DIST.tar.xz bs=1 seek=4096 conv=notrunc status=none"
expect_rejected "altered keyring"         "printf x >> release-keys-$NODE_RELEASE_KEYS_COMMIT.kbx"
(( fails == 0 )) || die "$fails tampered inputs were accepted"
