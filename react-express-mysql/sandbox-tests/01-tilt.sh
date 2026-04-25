#!/usr/bin/env bash
# Tilt sandbox test: spins up a kind cluster, runs `tilt ci` to build+deploy
# a tiny app, then verifies the deployment is rolled out.
# Stresses: privileged containers (kind nodes), nested networking, image
# loading, file watchers.
set -euo pipefail

NAME=tilt-sandbox-test
SUDO=$([ "$(id -u)" -eq 0 ] && echo "" || echo "sudo")

# Prereqs
command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }
if ! command -v kind >/dev/null; then
  curl -fsSL https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64 -o /tmp/kind
  chmod +x /tmp/kind && $SUDO mv /tmp/kind /usr/local/bin/kind
fi
if ! command -v kubectl >/dev/null; then
  curl -fsSL https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl -o /tmp/kubectl
  chmod +x /tmp/kubectl && $SUDO mv /tmp/kubectl /usr/local/bin/kubectl
fi
if ! command -v tilt >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash
fi

WORK=$(mktemp -d)
trap "kind delete cluster --name $NAME 2>/dev/null || true; rm -rf $WORK" EXIT

cd "$WORK"
kind create cluster --name $NAME --wait 90s

cat > Tiltfile <<'EOF'
docker_build('sandbox/hello', '.', dockerfile_contents='''
FROM nginx:alpine
RUN echo "hello from tilt" > /usr/share/nginx/html/index.html
''')
k8s_yaml(blob('''
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 1
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      containers:
      - name: hello
        image: sandbox/hello
        ports: [ { containerPort: 80 } ]
'''))
k8s_resource('hello')
EOF

tilt ci --timeout 5m
kubectl rollout status deploy/hello --timeout=120s
kubectl get pod -l app=hello -o jsonpath='{.items[0].status.phase}' | grep -q Running

echo "PASS: tilt"
