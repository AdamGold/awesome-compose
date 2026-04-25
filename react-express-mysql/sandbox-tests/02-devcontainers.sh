#!/usr/bin/env bash
# Devcontainer sandbox test: builds and starts a devcontainer, runs a
# postCreateCommand, starts an HTTP server inside the container, and curls
# it to verify the container actually serves traffic.
# Uses an image with Node pre-installed instead of a ghcr.io feature, to
# avoid sandboxes that block ghcr without credentials.
# Stresses: image pull + run, postCreateCommand hook, exec lifecycle,
# in-container TCP loopback.
set -euo pipefail

command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }
command -v node >/dev/null || { echo "FAIL: node/npm needed to install devcontainer CLI"; exit 1; }

if ! command -v devcontainer >/dev/null; then
  npm install -g @devcontainers/cli
fi

WORK=$(mktemp -d)
cleanup() {
  docker ps -aq --filter "label=devcontainer.local_folder=$WORK" | xargs -r docker rm -f
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/.devcontainer"
cat > "$WORK/.devcontainer/devcontainer.json" <<'EOF'
{
  "image": "mcr.microsoft.com/devcontainers/javascript-node:20",
  "postCreateCommand": "node --version > /tmp/node-version.txt && echo postcreate-ok > /tmp/marker"
}
EOF

devcontainer up --workspace-folder "$WORK"

marker=$(devcontainer exec --workspace-folder "$WORK" cat /tmp/marker)
node_v=$(devcontainer exec --workspace-folder "$WORK" cat /tmp/node-version.txt)

[ "$marker" = "postcreate-ok" ] || { echo "FAIL: postCreateCommand did not run"; exit 1; }
[[ "$node_v" =~ ^v[0-9]+\. ]] || { echo "FAIL: node not runnable (got $node_v)"; exit 1; }

# Start a tiny HTTP server inside the container, then curl it from inside.
# The server is daemonized so it survives this exec; the curl runs in a
# separate exec to prove cross-exec process persistence + loopback networking.
devcontainer exec --workspace-folder "$WORK" sh -c '
  nohup node -e "require(\"http\").createServer((_,s)=>s.end(\"devcontainer-served-ok\")).listen(8765)" \
    </dev/null >/tmp/srv.log 2>&1 &
  disown || true
'

# Give it a moment to bind
sleep 2

resp=$(devcontainer exec --workspace-folder "$WORK" sh -c 'curl -sf --max-time 5 http://localhost:8765/' || true)
if [ "$resp" != "devcontainer-served-ok" ]; then
  echo "FAIL: in-container HTTP server unreachable (got: '$resp')"
  devcontainer exec --workspace-folder "$WORK" cat /tmp/srv.log || true
  exit 1
fi

echo "PASS: devcontainers (node $node_v, in-container HTTP serves traffic)"
