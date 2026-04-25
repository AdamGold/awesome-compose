#!/usr/bin/env bash
# DinD sandbox test: runs docker:dind privileged, builds an image inside the
# inner daemon, runs it, verifies output. This is the test most likely to fail
# on userspace-syscall sandboxes (gVisor) and the canonical CI pattern.
# Stresses: --privileged, nested overlayfs, cgroup v2 nesting.
set -euo pipefail

NAME=dind-sandbox-test
trap "docker rm -f $NAME 2>/dev/null || true" EXIT

command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }

docker rm -f $NAME 2>/dev/null || true
docker run -d --privileged --name $NAME \
  -e DOCKER_TLS_CERTDIR= \
  docker:dind --tls=false

# Wait for inner dockerd
for i in $(seq 1 30); do
  if docker exec $NAME docker info >/dev/null 2>&1; then break; fi
  sleep 2
  [ "$i" = "30" ] && { echo "FAIL: inner dockerd never came up"; docker logs $NAME; exit 1; }
done

# Build & run inside the inner daemon
docker exec $NAME sh -ec '
  mkdir -p /tmp/build && cd /tmp/build
  cat > Dockerfile <<DF
FROM alpine:3.19
RUN echo nested-build-ok > /msg
CMD ["cat", "/msg"]
DF
  docker build -t inner:test .
  out=$(docker run --rm inner:test)
  [ "$out" = "nested-build-ok" ] || { echo "inner run produced: $out"; exit 1; }
'

echo "PASS: dind"
