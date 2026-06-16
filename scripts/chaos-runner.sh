#!/usr/bin/env bash
# Chaos runner — Phase 6 end-to-end test.
#
# For each scenario (crash, oom):
#   1. Inject failure by applying the scenario deployment
#   2. Watch Alertmanager until the expected alert fires
#   3. Watch for auto-remediation (bot deletes the scenario deployment)
#   4. Verify the main app is still healthy
#   5. Clean up any remaining scenario pods
#
# Prerequisites:
#   - monitoring-port-forward.sh running (Prometheus on :9090, Alertmanager on :9093)
#   - AIOps bot running with REMEDIATE=true (on :5001)
#
# Timing notes:
#   crash: pod crashes after 5 requests (~13s), CrashLoopBackOff after 3-4 restarts,
#          plus the alert rule's `for: 1m` hold — allow 240s total
#   oom:   pod OOMKills on first request, alert fires immediately — 120s is enough
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALERT_WAIT_SECS="${ALERT_WAIT_SECS:-240}"
REMEDIATION_WAIT_SECS="${REMEDIATION_WAIT_SECS:-60}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
pass()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
info()    { echo -e "  ${YELLOW}→${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

OVERALL_PASS=true

# ---------------------------------------------------------------------------
run_chaos_test() {
  local name="$1"           # e.g. crash
  local alert_name="$2"     # e.g. HelloWorldPodCrashLooping
  local scenario_dir="$3"   # e.g. scenarios/crash
  local dep_name="hello-world-app-${name}"

  section "Chaos test: ${name}"
  info "Applying ${scenario_dir}/deployment.yaml ..."
  kubectl apply -f "${REPO_ROOT}/${scenario_dir}/deployment.yaml"

  # ── Wait for alert to fire (poll Prometheus directly) ─────────────────
  info "Waiting up to ${ALERT_WAIT_SECS}s for alert '${alert_name}' to fire ..."
  local elapsed=0
  while true; do
    local count
    count=$(curl -s "http://localhost:9090/api/v1/alerts" \
      2>/dev/null \
      | python3 -c "
import json,sys
d=json.load(sys.stdin)
alerts=[a for a in d.get('data',{}).get('alerts',[])
        if a.get('labels',{}).get('alertname')=='${alert_name}' and a.get('state')=='firing']
print(len(alerts))" 2>/dev/null || echo "0")

    if [[ "${count}" -gt 0 ]]; then
      pass "Alert '${alert_name}' is firing"
      break
    fi

    if [[ "${elapsed}" -ge "${ALERT_WAIT_SECS}" ]]; then
      fail "Alert '${alert_name}' did not fire within ${ALERT_WAIT_SECS}s"
      kubectl delete -f "${REPO_ROOT}/${scenario_dir}/deployment.yaml" --ignore-not-found 2>/dev/null
      OVERALL_PASS=false
      return
    fi
    sleep 5; elapsed=$((elapsed + 5))
    echo -ne "\r    ...${elapsed}s / ${ALERT_WAIT_SECS}s"
  done
  echo ""

  # ── Wait for bot to remediate ──────────────────────────────────────────
  info "Waiting up to ${REMEDIATION_WAIT_SECS}s for auto-remediation ..."
  elapsed=0
  while true; do
    local pod_count
    pod_count=$(kubectl get deployment "${dep_name}" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ "${pod_count}" -eq 0 ]]; then
      pass "Scenario deployment '${dep_name}' removed by auto-remediation"
      break
    fi

    if [[ "${elapsed}" -ge "${REMEDIATION_WAIT_SECS}" ]]; then
      fail "Auto-remediation did not remove '${dep_name}' within ${REMEDIATION_WAIT_SECS}s"
      fail "Is the bot running with REMEDIATE=true?"
      kubectl delete deployment "${dep_name}" --ignore-not-found 2>/dev/null
      OVERALL_PASS=false
      return
    fi
    sleep 5; elapsed=$((elapsed + 5))
    echo -ne "\r    ...${elapsed}s / ${REMEDIATION_WAIT_SECS}s"
  done
  echo ""

  # ── Verify main app is still healthy ──────────────────────────────────
  info "Verifying main app health ..."
  local ready
  ready=$(kubectl get deployment hello-world-app \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${ready:-0}" -gt 0 ]]; then
    pass "Main app: ${ready} ready replica(s)"
  else
    fail "Main app has no ready replicas after chaos test"
    OVERALL_PASS=false
  fi

  local http_status
  http_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 3 http://localhost:30000 || echo "000")
  if [[ "${http_status}" == "200" ]]; then
    pass "App endpoint http://localhost:30000 → HTTP ${http_status}"
  else
    fail "App endpoint returned HTTP ${http_status}"
    OVERALL_PASS=false
  fi
}

# ---------------------------------------------------------------------------
section "Pre-flight checks"

check_port() {
  local port="$1" label="$2"
  if curl -s --max-time 2 "http://localhost:${port}/-/healthy" &>/dev/null || \
     curl -s --max-time 2 "http://localhost:${port}/health" &>/dev/null || \
     curl -s --max-time 2 "http://localhost:${port}/api/v1/alerts" &>/dev/null; then
    pass "Port ${port} reachable (${label})"
  else
    fail "Port ${port} not reachable — start: ${label}"
    exit 1
  fi
}
check_port 9090 "Prometheus — run: bash scripts/monitoring-port-forward.sh"
check_port 5001 "AIOps bot  — run: cd aioops-bot && REMEDIATE=true venv/bin/python bot.py"

# Run scenarios
run_chaos_test "crash" "HelloWorldPodCrashLooping" "scenarios/crash"
run_chaos_test "oom"   "HelloWorldPodOOMKilled"    "scenarios/oom"

# ---------------------------------------------------------------------------
section "Summary"
if [[ "${OVERALL_PASS}" == "true" ]]; then
  echo -e "${GREEN}✓ All chaos tests passed — alert → remediation → recovery loop works end-to-end.${NC}"
else
  echo -e "${RED}✗ One or more chaos tests failed — see output above.${NC}"
  exit 1
fi
