#!/usr/bin/env bash
# Phase 1 setup: build image, create Kind cluster, deploy app, verify it's reachable.
set -euo pipefail

CLUSTER_NAME="hello-world-cluster"
APP_NAME="hello-world-app"
IMAGE="${APP_NAME}:latest"
NAMESPACE="default"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."
for tool in docker kind kubectl; do
  command -v "$tool" &>/dev/null || error "'$tool' not found in PATH"
done
docker info &>/dev/null || error "Docker daemon is not running"
info "All prerequisites satisfied."

# ── 2. Kind cluster ───────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  info "Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --config "${REPO_ROOT}/kind-config.yaml"
  info "Cluster created."
fi

info "Setting kubectl context to kind-${CLUSTER_NAME}..."
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 3. Build Docker image ─────────────────────────────────────────────────────
info "Building Docker image '${IMAGE}'..."
docker build -t "${IMAGE}" "${REPO_ROOT}"
info "Image built."

# ── 4. Load image into Kind ───────────────────────────────────────────────────
info "Loading image into Kind cluster '${CLUSTER_NAME}'..."
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"
info "Image loaded."

# ── 5. Apply manifests ────────────────────────────────────────────────────────
info "Applying Kubernetes manifests..."
kubectl apply -f "${REPO_ROOT}/k8s/deployment.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/service.yaml"

# ── 6. Wait for rollout ───────────────────────────────────────────────────────
info "Waiting for deployment to be ready (up to 120s)..."
kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=120s
info "Deployment is ready."

# ── 7. Verify reachability ────────────────────────────────────────────────────
info "Verifying app is reachable at http://localhost:30000 ..."
for i in {1..10}; do
  RESPONSE=$(curl -s --max-time 3 http://localhost:30000 2>/dev/null || true)
  if [[ "${RESPONSE}" == *"Hello World"* ]]; then
    echo ""
    echo -e "${GREEN}✓ App is reachable!${NC} Response: ${RESPONSE}"
    echo ""
    info "Phase 1 setup complete."
    echo ""
    echo "  App URL  : http://localhost:30000"
    echo "  Logs     : kubectl logs -f deployment/${APP_NAME}"
    echo "  Status   : kubectl get pods,svc -n ${NAMESPACE}"
    echo "  Teardown : kind delete cluster --name ${CLUSTER_NAME}"
    echo ""
    exit 0
  fi
  warn "Attempt ${i}/10: not ready yet, retrying in 5s..."
  sleep 5
done

error "App did not respond after 10 attempts. Check pod logs:
  kubectl get pods -n ${NAMESPACE}
  kubectl describe pod -l app=${APP_NAME} -n ${NAMESPACE}
  kubectl logs -l app=${APP_NAME} -n ${NAMESPACE}"
