#!/usr/bin/env bash
# Phase 6 setup: auto-remediation + chaos testing.
# Verifies prerequisites are in place, then prints the runbook for the demo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
section "Prerequisites"
for tool in kubectl python3; do
  command -v "$tool" &>/dev/null || error "'$tool' not found in PATH"
done
kubectl config current-context | grep -q "kind-hello-world-cluster" \
  || error "kubectl context is not kind-hello-world-cluster"
[[ -d "${REPO_ROOT}/aioops-bot/venv" ]] \
  || error "Python venv missing — run scripts/phase5-setup.sh first"
info "Prerequisites OK."

# ── 2. Verify scenarios use registry image ────────────────────────────────────
section "Scenario manifests"
for scenario in crash oom; do
  if grep -q "localhost:6000" "${REPO_ROOT}/scenarios/${scenario}/deployment.yaml"; then
    info "scenarios/${scenario}/deployment.yaml uses local registry ✓"
  else
    error "scenarios/${scenario}/deployment.yaml still uses bare image tag — this was fixed in Phase 6 commit"
  fi
done

# ── 3. Verify PrometheusRules are active ──────────────────────────────────────
section "PrometheusRules"
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &>/tmp/pf-ph6.log &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
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

if [[ "${RULE_COUNT}" -ge 5 ]]; then
  info "${RULE_COUNT} HelloWorld alert rules active in Prometheus ✓"
else
  warn "Only ${RULE_COUNT} rules found — PrometheusRule may still be syncing"
fi

# ── 4. Print demo runbook ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ Phase 6 setup complete!${NC}"
echo ""
echo "  The pipeline is now fully wired:"
echo "  alert fires → bot triages → bot remediates → ArgoCD self-heals"
echo ""
echo "  ┌─ Step 1: start monitoring UIs + Loki ────────────────────────────┐"
echo "  │  bash scripts/monitoring-port-forward.sh                         │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─ Step 2: start AIOps bot with remediation ON ────────────────────┐"
echo "  │  cd aioops-bot                                                   │"
echo "  │  ANTHROPIC_API_KEY=sk-... REMEDIATE=true venv/bin/python bot.py  │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─ Step 3: run automated chaos tests ──────────────────────────────┐"
echo "  │  bash scripts/chaos-runner.sh                                    │"
echo "  │                                                                   │"
echo "  │  What happens:                                                    │"
echo "  │    crash scenario  →  CrashLoopBackOff alert  →  bot deletes dep │"
echo "  │    oom scenario    →  OOMKilled alert          →  bot deletes dep │"
echo "  │                                                                   │"
echo "  │  Main app (hello-world-app) stays healthy throughout.            │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─ Bonus: test GitOps memory remediation ───────────────────────────┐"
echo "  │  # Simulate the main app getting OOM-killed:                      │"
echo "  │  curl -s -X POST http://localhost:5001/webhook \\                  │"
echo "  │    -H 'Content-Type: application/json' \\                          │"
echo "  │    -d '{\"alerts\":[{\"status\":\"firing\",\"labels\":{               │"
echo "  │      \"alertname\":\"HelloWorldPodOOMKilled\",\"severity\":\"warning\", │"
echo "  │      \"pod\":\"hello-world-app-main\",\"namespace\":\"default\"},      │"
echo "  │      \"annotations\":{},\"startsAt\":\"2026-01-01T00:00:00Z\"}]}'      │"
echo "  │                                                                   │"
echo "  │  Expected: bot bumps limits.memory in deployment.yaml, commits,  │"
echo "  │            pushes, ArgoCD detects → rolling redeploy.            │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
