#!/usr/bin/env bash
# Phase 2 setup: local registry + Kind cluster with containerd mirror + deploy.
# Run this once to upgrade from Phase 1. Idempotent on re-runs.
set -euo pipefail

CLUSTER_NAME="hello-world-cluster"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="6000"
REGISTRY="localhost:${REGISTRY_PORT}"
APP_NAME="hello-world-app"
NAMESPACE="default"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."
for tool in docker kind kubectl npm; do
  command -v "$tool" &>/dev/null || error "'$tool' not found in PATH"
done
docker info &>/dev/null || error "Docker daemon is not running"
info "All prerequisites satisfied."

# ── 2. Local registry ─────────────────────────────────────────────────────────
if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  info "Registry '${REGISTRY_NAME}' already running on port ${REGISTRY_PORT}."
else
  info "Starting local registry on localhost:${REGISTRY_PORT}..."
  docker run -d \
    --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --name "${REGISTRY_NAME}" \
    registry:2
  info "Registry started."
fi

# ── 3. Kind cluster with containerd mirror ────────────────────────────────────
NEEDS_RECREATE=false
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  # Check if the containerd mirror is already configured
  if docker exec "${CLUSTER_NAME}-control-plane" \
       grep -q "kind-registry" /etc/containerd/config.toml 2>/dev/null; then
    warn "Cluster '${CLUSTER_NAME}' already has registry mirror — skipping recreation."
  else
    warn "Cluster '${CLUSTER_NAME}' exists but lacks the registry mirror. Recreating..."
    kind delete cluster --name "${CLUSTER_NAME}"
    NEEDS_RECREATE=true
  fi
else
  NEEDS_RECREATE=true
fi

if [[ "${NEEDS_RECREATE}" == true ]]; then
  info "Creating Kind cluster '${CLUSTER_NAME}' with containerd registry mirror..."
  kind create cluster --config "${REPO_ROOT}/kind-config.yaml"
  info "Cluster created."
fi

info "Setting kubectl context..."
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 4. Connect registry to Kind network ───────────────────────────────────────
if docker network inspect kind 2>/dev/null | grep -q "\"${REGISTRY_NAME}\""; then
  info "Registry already connected to Kind network."
else
  info "Connecting registry to Kind network..."
  docker network connect kind "${REGISTRY_NAME}"
  info "Connected."
fi

# ── 5. Advertise registry in the cluster ─────────────────────────────────────
info "Creating registry ConfigMap in kube-public..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# ── 6. Install dependencies & run tests ──────────────────────────────────────
info "Installing Node.js dependencies..."
(cd "${REPO_ROOT}" && npm install)
info "Running tests..."
(cd "${REPO_ROOT}" && npm test)
info "Tests passed."

# ── 7. Build & push to local registry ────────────────────────────────────────
SHA=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "local")
VERSIONED="${REGISTRY}/${APP_NAME}:${SHA}"
LATEST="${REGISTRY}/${APP_NAME}:latest"

info "Building image ${LATEST}..."
docker build -t "${VERSIONED}" -t "${LATEST}" "${REPO_ROOT}"

info "Pushing to local registry..."
docker push "${VERSIONED}"
docker push "${LATEST}"
info "Image available at ${LATEST}"

# ── 8. Deploy ─────────────────────────────────────────────────────────────────
info "Applying Kubernetes manifests..."
kubectl apply -f "${REPO_ROOT}/k8s/deployment.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/service.yaml"

info "Waiting for rollout (up to 120s)..."
kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=120s
info "Deployment ready."

# ── 9. Verify ─────────────────────────────────────────────────────────────────
info "Verifying app at http://localhost:30000 ..."
for i in {1..10}; do
  RESPONSE=$(curl -s --max-time 3 http://localhost:30000 2>/dev/null || true)
  if [[ "${RESPONSE}" == *"Hello World"* ]]; then
    echo ""
    echo -e "${GREEN}✓ Phase 2 setup complete!${NC}"
    echo ""
    echo "  Registry : ${REGISTRY}  (image: ${VERSIONED})"
    echo "  App URL  : http://localhost:30000"
    echo ""
    echo "  Local CI : bash scripts/ci-local.sh   # test → build → push → deploy"
    echo "  Logs     : kubectl logs -f deployment/${APP_NAME}"
    echo "  Teardown : kind delete cluster --name ${CLUSTER_NAME}"
    echo ""
    exit 0
  fi
  warn "Attempt ${i}/10: not ready, retrying in 5s..."
  sleep 5
done

error "App did not respond. Check:
  kubectl get pods -n ${NAMESPACE}
  kubectl describe pod -l app=${APP_NAME} -n ${NAMESPACE}"
