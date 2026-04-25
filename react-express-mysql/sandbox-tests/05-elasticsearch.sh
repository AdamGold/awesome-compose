#!/usr/bin/env bash
# Elasticsearch sandbox test: single-node ES 8, indexes a doc, refreshes,
# searches. Notoriously sensitive to vm.max_map_count and to memory limits.
# If this fails on the new sandbox but passed on Kata, suspect host sysctls
# (Kata kernels expose their own sysctl namespace, replacements often don't).
set -euo pipefail

NAME=es-sandbox-test
SUDO=$([ "$(id -u)" -eq 0 ] && echo "" || echo "sudo")
trap "docker rm -f $NAME 2>/dev/null || true" EXIT

command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }

# ES requires this; will fail at boot with a clear bootstrap-check error if not set.
current=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [ "$current" -lt 262144 ]; then
  echo "vm.max_map_count is $current; raising to 262144..."
  $SUDO sysctl -w vm.max_map_count=262144 || echo "WARN: could not raise; ES may refuse to start"
fi

docker rm -f $NAME 2>/dev/null || true
docker run -d --name $NAME \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=false" \
  -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
  -p 9200:9200 \
  docker.elastic.co/elasticsearch/elasticsearch:8.13.0

for i in $(seq 1 60); do
  health=$(curl -sf http://localhost:9200/_cluster/health 2>/dev/null || true)
  if [ -n "$health" ] && echo "$health" | grep -qE '"status":"(green|yellow)"'; then break; fi
  sleep 2
  [ "$i" = "60" ] && { echo "FAIL: ES never reported healthy"; docker logs --tail 80 $NAME; exit 1; }
done

curl -sf -X POST http://localhost:9200/sandbox/_doc/1 \
  -H 'Content-Type: application/json' \
  -d '{"msg":"hello-from-sandbox","n":42}' >/dev/null
curl -sf -X POST http://localhost:9200/sandbox/_refresh >/dev/null

resp=$(curl -sf "http://localhost:9200/sandbox/_search?q=msg:hello-from-sandbox")
hits=$(echo "$resp" | grep -oE '"total":\{"value":[0-9]+' | grep -oE '[0-9]+$')
[ "${hits:-0}" -ge 1 ] || { echo "FAIL: search returned $hits hits"; echo "$resp"; exit 1; }

echo "PASS: elasticsearch ($hits hits)"
