#!/usr/bin/env bash
# Exports the filesystem of the digest-pinned debian:trixie-slim image for ARCH to
# .work/<arch>/rootfs.tar. Nothing in the image runs: the container is created, exported
# and removed, so this works for either architecture on any host without emulation.
. "$(dirname "$0")/lib.sh"
set_arch "${1:-}"

image=debian@$DEBIAN_DIGEST
docker pull -q --platform "$DOCKER_PLATFORM" "$image" >/dev/null
got=$(docker image inspect --platform "$DOCKER_PLATFORM" --format '{{.Os}}/{{.Architecture}}' "$image")
[[ $got == "$DOCKER_PLATFORM" ]] || die "$image is $got, expected $DOCKER_PLATFORM"

mkdir -p "$WORK/$ARCH"
cid=$(docker create --platform "$DOCKER_PLATFORM" "$image" /nonexistent)
trap 'docker rm "$cid" >/dev/null' EXIT
docker export -o "$WORK/$ARCH/rootfs.tar" "$cid"
echo "exported $image ($DOCKER_PLATFORM)"
