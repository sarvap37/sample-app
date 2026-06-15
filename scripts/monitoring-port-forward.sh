#!/usr/bin/env bash
# Start port-forwards for Grafana, Prometheus, and Alertmanager.
# Run in a dedicated terminal — Ctrl+C stops all forwards.
set -euo pipefail

NS="monitoring"

for tool in kubectl; do
  command -v "$tool" &>/dev/null || { echo "ERROR: '$tool' not in PATH"; exit 1; }
done

# Resolve Grafana service name (varies by chart version)
GRAFANA_SVC=$(kubectl get svc -n "${NS}" -l "app.kubernetes.io/name=grafana" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "${GRAFANA_SVC}" ]]; then
  echo "ERROR: Grafana service not found in namespace '${NS}'. Run phase4-setup.sh first."
  exit 1
fi

echo "━━━ Monitoring port-forwards ━━━"
echo "  Grafana      → http://localhost:3000  (admin / admin)"
echo "  Prometheus   → http://localhost:9090"
echo "  Alertmanager → http://localhost:9093"
echo "  Loki         → http://localhost:3100  (AIOps bot log queries)"
echo ""
echo "  Press Ctrl+C to stop."
echo ""

kubectl port-forward -n "${NS}" "svc/${GRAFANA_SVC}" 3000:80 &
PF_PIDS=($!)

kubectl port-forward -n "${NS}" svc/prometheus-operated 9090:9090 &
PF_PIDS+=($!)

kubectl port-forward -n "${NS}" svc/alertmanager-operated 9093:9093 &
PF_PIDS+=($!)

kubectl port-forward -n "${NS}" svc/loki-stack 3100:3100 &
PF_PIDS+=($!)

cleanup() {
  echo ""
  echo "Stopping port-forwards..."
  kill "${PF_PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait
