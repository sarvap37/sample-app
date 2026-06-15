#!/usr/bin/env bash
# Phase 5 setup: alerting rules + AIOps triage bot.
# - Applies PrometheusRule (via ArgoCD) and updates Alertmanager config (via Helm)
# - Installs Python deps for the AIOps bot
# - Prints instructions for running the end-to-end demo
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
for tool in kubectl helm python3 docker; do
  command -v "$tool" &>/dev/null || error "'$tool' not found in PATH"
done
kubectl config current-context | grep -q "kind-hello-world-cluster" \
  || error "kubectl context is not kind-hello-world-cluster"
info "Prerequisites OK."

# ── 2. Detect host IP reachable from inside Kind ──────────────────────────────
section "Host gateway detection"
HOST_IP=$(docker network inspect kind --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
[[ -n "${HOST_IP}" ]] || error "Could not determine Kind network gateway. Is the cluster running?"
info "Host IP (from inside Kind): ${HOST_IP}"
info "Alertmanager will send webhooks to: http://${HOST_IP}:5001/webhook"

# ── 3. Update Alertmanager config via helm upgrade ────────────────────────────
section "Updating Alertmanager webhook config"
ALERTMANAGER_VALUES=$(mktemp /tmp/alertmanager-config-XXXXXX.yaml)
trap "rm -f ${ALERTMANAGER_VALUES}" EXIT

sed "s|AIOOPS_BOT_HOST|${HOST_IP}|g" \
  "${REPO_ROOT}/monitoring/alertmanager-config-template.yaml" > "${ALERTMANAGER_VALUES}"

info "Running helm upgrade (kube-prometheus-stack)..."
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE}" \
  --values "${REPO_ROOT}/monitoring/kube-prometheus-stack-values.yaml" \
  --values "${ALERTMANAGER_VALUES}" \
  --wait --timeout 5m
info "Alertmanager configured."

# ── 4. Apply PrometheusRule + force ArgoCD sync ────────────────────────────────
section "PrometheusRule via ArgoCD GitOps"
ARGOCD_NS="argocd"
until kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret &>/dev/null; do sleep 3; done
ARGOCD_PASS=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode)
argocd login \
  --port-forward --port-forward-namespace "${ARGOCD_NS}" \
  --username admin --password "${ARGOCD_PASS}" --insecure
argocd app sync hello-world-app \
  --port-forward --port-forward-namespace "${ARGOCD_NS}" \
  --force --timeout 60
argocd app wait hello-world-app \
  --port-forward --port-forward-namespace "${ARGOCD_NS}" \
  --health --timeout 60
info "PrometheusRule synced."

# ── 5. Verify PrometheusRule is loaded ────────────────────────────────────────
section "Verifying alert rules loaded in Prometheus"
info "Port-forwarding Prometheus to check rules..."
kubectl port-forward -n "${NAMESPACE}" svc/prometheus-operated 9090:9090 &>/tmp/pf-prom5.log &
PF_PID=$!
sleep 4

RULE_COUNT=$(curl -s "http://localhost:9090/api/v1/rules" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
rules = [r for g in d.get('data',{}).get('groups',[]) for r in g.get('rules',[])
         if r.get('name','').startswith('HelloWorld')]
print(len(rules))
" 2>/dev/null || echo "0")

kill "${PF_PID}" 2>/dev/null || true

if [[ "${RULE_COUNT}" -gt 0 ]]; then
  info "✓ ${RULE_COUNT} HelloWorld alert rules active in Prometheus."
else
  warn "Rules not yet visible in Prometheus — they may take up to 30s to appear."
fi

# ── 6. Install Python deps for the AIOps bot ─────────────────────────────────
section "Installing AIOps bot dependencies"
BOT_DIR="${REPO_ROOT}/aioops-bot"
if [[ ! -d "${BOT_DIR}/venv" ]]; then
  python3 -m venv "${BOT_DIR}/venv"
fi
"${BOT_DIR}/venv/bin/pip" install -q -r "${BOT_DIR}/requirements.txt"
info "Python dependencies installed in aioops-bot/venv/"

# ── 7. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ Phase 5 setup complete!${NC}"
echo ""
echo "  ┌─ Terminal 1: monitoring UIs ─────────────────────────────────────┐"
echo "  │  bash scripts/monitoring-port-forward.sh                         │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─ Terminal 2: AIOps triage bot ───────────────────────────────────┐"
echo "  │  cd aioops-bot                                                   │"
echo "  │  ANTHROPIC_API_KEY=sk-... venv/bin/python bot.py                 │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─ Terminal 3: trigger a failure scenario ──────────────────────────┐"
echo "  │  # CrashLoopBackOff (alert fires after ~1 min):                  │"
echo "  │  kubectl apply -f scenarios/deployment-crash.yaml                 │"
echo "  │                                                                   │"
echo "  │  # OOMKilled (alert fires immediately on first OOM):              │"
echo "  │  kubectl apply -f scenarios/deployment-oom.yaml                  │"
echo "  │                                                                   │"
echo "  │  # Test bot without waiting for a real alert:                    │"
echo "  │  curl -s -X POST http://localhost:5001/test | jq                 │"
echo "  │                                                                   │"
echo "  │  # Clean up scenario pods:                                        │"
echo "  │  kubectl delete -f scenarios/deployment-crash.yaml 2>/dev/null   │"
echo "  │  kubectl delete -f scenarios/deployment-oom.yaml 2>/dev/null     │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Alertmanager UI  → http://localhost:9093  (run monitoring-port-forward.sh first)"
echo "  Active rules     → http://localhost:9090/alerts"
echo ""
