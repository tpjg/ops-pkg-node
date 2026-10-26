#!/usr/bin/env bash
# Tests for ARCH: tampered Node downloads must be rejected (scripts/test-verify.sh), then the
# acceptance tests boot dist/'s package in the test container (test/Dockerfile). The test
# driver runs on the verified official Node build for this host's architecture.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"
in_tools scripts/fetch-node.sh "$ARCH" >/dev/null
in_tools scripts/test-verify.sh "$ARCH"
in_tools scripts/fetch-node.sh "$(host_arch)"
in_test scripts/acceptance.sh "$ARCH"
