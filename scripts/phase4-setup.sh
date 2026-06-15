#!/usr/bin/env bash
# Phase 4 setup: install Prometheus + Grafana + Alertmanager + Loki in the Kind cluster.
# Run once after phase3-setup.sh. Idempotent on re-runs (helm upgrade --install).
set -euo pipefail

NAMESPACE="monitoring"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
section "Prerequisites"
for tool in kubectl helm; do
  command -v "$tool" &>/dev/null || error "'$tool' not found in PATH"
done
kubectl config current-context | grep -q "kind-hello-world-cluster" \
  || error "kubectl context is not kind-hello-world-cluster — run phase3-setup.sh first"

# ── 2. Install prom-client locally (needed for npm test) ─────────────────────
section "Installing prom-client"
info "Running npm install in ${REPO_ROOT}..."
(cd "${REPO_ROOT}" && npm install)
info "Dependencies installed."

# ── 3. Add Helm repos ─────────────────────────────────────────────────────────
section "Helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
info "Repos up to date."

# ── 4. Create monitoring namespace ────────────────────────────────────────────
section "Monitoring namespace"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
info "Namespace '${NAMESPACE}' ready."

# ── 5. Install kube-prometheus-stack ─────────────────────────────────────────
section "kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"
info "This may take 5–8 minutes on first run..."
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE}" \
  --values "${REPO_ROOT}/monitoring/kube-prometheus-stack-values.yaml" \
  --wait --timeout 10m
info "kube-prometheus-stack installed."

# ── 6. Install loki-stack ─────────────────────────────────────────────────────
section "loki-stack (Loki + Promtail)"
helm upgrade --install loki-stack \
  grafana/loki-stack \
  --namespace "${NAMESPACE}" \
  --values "${REPO_ROOT}/monitoring/loki-stack-values.yaml" \
  --wait --timeout 5m
info "loki-stack installed."

# ── 7. Verify pods ────────────────────────────────────────────────────────────
section "Verification"
echo ""
kubectl get pods -n "${NAMESPACE}"

# ── 8. Print summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ Phase 4 setup complete!${NC}"
echo ""
echo "  Next: deploy updated app with metrics endpoint"
echo "    bash scripts/ci-local.sh"
echo ""
echo "  Then start monitoring UIs:"
echo "    bash scripts/monitoring-port-forward.sh"
echo ""
echo "  Grafana      → http://localhost:3000  (admin / admin)"
echo "  Prometheus   → http://localhost:9090"
echo "  Alertmanager → http://localhost:9093"
echo ""
echo "  Tip: In Grafana → Explore → select Loki to browse pod logs."
echo "       In Grafana → Explore → select Prometheus, query:"
echo "         http_requests_total{job=\"hello-world-app\"}"
echo ""
