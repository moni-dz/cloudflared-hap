#!/usr/bin/env sh

PLATFORM="linux/arm/v7"
VERSION=0.1.0

set -eu

rm -f mikrotik-container.tar

docker buildx build \
  --no-cache \
  --platform $PLATFORM \
  --builder arm64-builder \
  --load -t ghcr.io/fluent-networks/mikrotik-container:$VERSION .

skopeo copy docker-daemon:ghcr.io/fluent-networks/mikrotik-container:$VERSION docker-archive:mikrotik-container.tar
