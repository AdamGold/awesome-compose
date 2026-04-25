#!/usr/bin/env bash
# kind sandbox test: creates a 3-node cluster (1 control-plane + 2 workers),
# deploys nginx + a Service, runs a Job that curls the Service from another
# pod, asserts the Job completes successfully.
# Stresses: privileged kind-node containers, nested cgroups, CNI (kindnet),
# kube-proxy iptables programming, CoreDNS resolution, pod-to-pod networking
# across worker nodes.
set -euo pipefail

NAME=kind-sandbox-test
SUDO=$([ "$(id -u)" -eq 0 ] && echo "" || echo "sudo")

command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }
if ! command -v kind >/dev/null; then
  curl -fsSL https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64 -o /tmp/kind
  chmod +x /tmp/kind && $SUDO mv /tmp/kind /usr/local/bin/kind
fi
if ! command -v kubectl >/dev/null; then
  curl -fsSL https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl -o /tmp/kubectl
  chmod +x /tmp/kubectl && $SUDO mv /tmp/kubectl /usr/local/bin/kubectl
fi

WORK=$(mktemp -d)
trap "kind delete cluster --name $NAME 2>/dev/null || true; rm -rf $WORK" EXIT

cat > "$WORK/cluster.yaml" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kind create cluster --name $NAME --config "$WORK/cluster.yaml" --wait 180s

# Node count
nodes=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
[ "$nodes" -eq 3 ] || { echo "FAIL: expected 3 nodes, got $nodes"; kubectl get nodes; exit 1; }

# All nodes Ready
not_ready=$(kubectl get nodes --no-headers | awk '$2 != "Ready" { print $1 }')
[ -z "$not_ready" ] || { echo "FAIL: nodes not Ready: $not_ready"; exit 1; }

# Workload + service spread across both workers
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec:
  replicas: 2
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector: { matchLabels: { app: web } }
              topologyKey: kubernetes.io/hostname
      containers:
      - name: nginx
        image: nginx:alpine
        ports: [ { containerPort: 80 } ]
---
apiVersion: v1
kind: Service
metadata: { name: web }
spec:
  selector: { app: web }
  ports: [ { port: 80, targetPort: 80 } ]
EOF

kubectl rollout status deploy/web --timeout=180s

# Pod-to-pod via cluster DNS
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: { name: curl-test }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: curl
        image: curlimages/curl:8.7.1
        command: ["sh", "-c"]
        args:
          - |
            for i in $(seq 1 10); do
              curl -sf http://web/ | grep -q "Welcome to nginx" && exit 0
              sleep 3
            done
            exit 1
EOF

if ! kubectl wait --for=condition=complete job/curl-test --timeout=180s; then
  echo "FAIL: curl-test job did not complete"
  kubectl describe job/curl-test
  kubectl logs job/curl-test --tail=50 || true
  exit 1
fi

echo "PASS: kind (3 nodes Ready, pod-to-pod via Service DNS works)"
