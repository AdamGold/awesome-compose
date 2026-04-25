#!/usr/bin/env bash
# Devcontainer sandbox test: builds and starts a devcontainer, installs a
# feature, runs a postCreateCommand, execs a verification command inside.
# Stresses: docker build with BuildKit, feature mount layering, exec lifecycle.
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
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/devcontainers/features/node:1": { "version": "20" }
  },
  "postCreateCommand": "node --version > /tmp/node-version.txt && echo postcreate-ok > /tmp/marker"
}
EOF

devcontainer up --workspace-folder "$WORK"

marker=$(devcontainer exec --workspace-folder "$WORK" cat /tmp/marker)
node_v=$(devcontainer exec --workspace-folder "$WORK" cat /tmp/node-version.txt)

[ "$marker" = "postcreate-ok" ] || { echo "FAIL: postCreateCommand did not run"; exit 1; }
[[ "$node_v" == v20* ]] || { echo "FAIL: node feature broken (got $node_v)"; exit 1; }

echo "PASS: devcontainers (node $node_v)"
