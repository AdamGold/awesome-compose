#!/usr/bin/env bash
# Postgres sandbox test: runs postgres:16, initializes pgbench at scale 10,
# runs a short benchmark, asserts non-zero TPS. A good fsync / shared-memory /
# I/O test that often surfaces overlayfs or aio quirks.
set -euo pipefail

NAME=pg-sandbox-test
trap "docker rm -f $NAME 2>/dev/null || true" EXIT

command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }

docker rm -f $NAME 2>/dev/null || true
docker run -d --name $NAME \
  -e POSTGRES_PASSWORD=test \
  -e POSTGRES_DB=bench \
  postgres:16

for i in $(seq 1 30); do
  if docker exec $NAME pg_isready -U postgres -d bench >/dev/null 2>&1; then break; fi
  sleep 1
  [ "$i" = "30" ] && { echo "FAIL: postgres never became ready"; docker logs $NAME; exit 1; }
done

docker exec $NAME pgbench -i -s 10 -U postgres bench
result=$(docker exec $NAME pgbench -c 8 -j 4 -T 10 -U postgres bench 2>&1)
echo "$result"

tps=$(echo "$result" | awk '/tps = / { print $3; exit }' | cut -d. -f1)
[ -n "$tps" ] && [ "$tps" -gt 0 ] || { echo "FAIL: no TPS measured"; exit 1; }

# Also verify a simple query works post-bench
docker exec $NAME psql -U postgres -d bench -c "SELECT count(*) FROM pgbench_accounts" \
  | grep -q "1000000"

echo "PASS: postgres (tps=$tps)"
