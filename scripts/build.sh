#!/usr/bin/env bash
# Builds dist/node_<version>_linux-<ARCH>.tar.gz and its .sha256 for ARCH (x64 | arm64).
# Works on any host with docker, for either architecture, without emulation: the tools
# container is native and the target-arch image is only exported, never run.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"
in_tools scripts/fetch-node.sh "$ARCH"
"$ROOT/scripts/export-sysroot.sh" "$ARCH"
in_tools scripts/build-package.sh "$ARCH"
