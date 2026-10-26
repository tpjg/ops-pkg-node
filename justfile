# Build, verify and test the Node.js 24 ops package. ARCH is x64 or arm64.
# Requires only docker and just; download, verification, packaging and tests run in
# digest-pinned containers. CI calls the same scripts.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Download the Node.js tarball and verify its signature and checksum
fetch ARCH:
    source scripts/lib.sh && in_tools scripts/fetch-node.sh {{ARCH}}

# Build dist/node_<version>_linux-<ARCH>.tar.gz and its .sha256
build ARCH:
    scripts/build.sh {{ARCH}}

# Boot dist/'s package with ops/QEMU in the test container and run the acceptance tests
test ARCH:
    scripts/test.sh {{ARCH}}

# Build and test both architectures, then compare with package/expected.sha256
all: (build "x64") (build "arm64") (check "x64") (check "arm64") (test "x64") (test "arm64")

# Compare dist/'s package with package/expected.sha256
check ARCH:
    scripts/check-expected.sh {{ARCH}}

# Build both architectures and record their checksums in package/expected.sha256
expected: (build "x64") (build "arm64")
    cat dist/*.sha256 > package/expected.sha256 && cat package/expected.sha256

# Install the pinned ops CLI and Nanos kernels for this host into .work/ (never touches ~/.ops)
ops:
    scripts/install-ops.sh

# Print the newest Node 24 LTS release on nodejs.org
latest:
    scripts/latest-node.sh

clean:
    chmod -R u+w .work 2>/dev/null || true
    rm -rf .work dist
