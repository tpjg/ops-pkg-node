# Build tools for scripts/fetch-node.sh and scripts/build-package.sh. This image never supplies
# files to the package; the sysroot comes from the target-arch image (scripts/export-sysroot.sh).
ARG DEBIAN_INDEX_DIGEST
FROM debian@${DEBIAN_INDEX_DIGEST}
ARG DEBIAN_SNAPSHOT
RUN sed -i \
      -e "s|^URIs: http://deb.debian.org/debian-security\$|URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|" \
      -e "s|^URIs: http://deb.debian.org/debian\$|URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
 && grep -q "snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" /etc/apt/sources.list.d/debian.sources \
 && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      binutils ca-certificates curl gpgv jq xz-utils \
 && rm -rf /var/lib/apt/lists/*
