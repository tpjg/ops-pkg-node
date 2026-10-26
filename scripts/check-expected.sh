#!/usr/bin/env bash
# Fails unless dist/'s package for ARCH has the sha256 recorded in package/expected.sha256.
# The expected values come from a build on another host (a developer machine, or the
# update-node workflow), so a match shows the build is reproducible across hosts.
# After an intended change to the package, record the new values with `just expected`.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"
want=$(awk -v f="$PKG_FILE" '$2 == f { print $1 }' "$ROOT/package/expected.sha256")
[[ -n $want ]] || die "$PKG_FILE is not in package/expected.sha256 (run 'just expected')"
check_sha256 "$DIST/$PKG_FILE" "$want"
echo "$PKG_FILE matches package/expected.sha256"
