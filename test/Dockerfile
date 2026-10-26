# Test environment for scripts/test.sh: QEMU, openssl and procps from a pinned Ubuntu snapshot.
# ca-certificates comes from the live archive first, because apt needs it to reach the snapshot
# service over https; apt verifies every archive's signatures either way.
ARG UBUNTU_INDEX_DIGEST
FROM ubuntu@${UBUNTU_INDEX_DIGEST}
ARG UBUNTU_SNAPSHOT
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates \
 && apt-get update --snapshot "${UBUNTU_SNAPSHOT}" \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --snapshot "${UBUNTU_SNAPSHOT}" \
      curl ipxe-qemu openssl procps qemu-system-arm qemu-system-x86 xz-utils \
 && rm -rf /var/lib/apt/lists/*
