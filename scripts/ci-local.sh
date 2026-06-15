#!/usr/bin/env bash
# Local CI pipeline: test → build → push to registry → rolling deploy.
# Mirrors what GitHub Actions does, but also pushes to the local Kind registry.
set -euo pipefail

REGISTRY="localhost:6000"
APP_NAME="hello-world-app"
NAMESPACE="default"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[CI]${NC} $*"; }
warn()  { echo -e "${YELLOW}[CI]${NC} $*"; }
error() { echo -e "${RED}[CI]${NC} $*" >&2; exit 1; }

SHA=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "local")
VERSIONED="${REGISTRY}/${APP_NAME}:${SHA}"
LATEST="${REGISTRY}/${APP_NAME}:latest"

# ── 1. Test ───────────────────────────────────────────────────────────────────
info "Running tests..."
(cd "${REPO_ROOT}" && npm test)
info "Tests passed."

# ── 2. Build ──────────────────────────────────────────────────────────────────
info "Building image ${VERSIONED}..."
docker build -t "${VERSIONED}" -t "${LATEST}" "${REPO_ROOT}"
info "Build complete."

# ── 3. Push to local registry ─────────────────────────────────────────────────
info "Pushing to local registry ${REGISTRY}..."
docker push "${VERSIONED}"
docker push "${LATEST}"
info "Push complete."

# ── 4. Rolling deploy ─────────────────────────────────────────────────────────
info "Deploying ${APP_NAME}:${SHA} to Kind cluster..."
kubectl set image deployment/"${APP_NAME}" \
  "${APP_NAME}=${VERSIONED}" \
  -n "${NAMESPACE}"
kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=120s
info "Rollout complete."

# ── 5. Verify ─────────────────────────────────────────────────────────────────
info "Verifying http://localhost:30000 ..."
for i in {1..6}; do
  RESPONSE=$(curl -s --max-time 3 http://localhost:30000 2>/dev/null || true)
  if [[ "${RESPONSE}" == *"Hello World"* ]]; then
    echo -e "\n${GREEN}✓ Deployed and reachable.${NC} sha=${SHA} response=${RESPONSE}"
    exit 0
  fi
  warn "Attempt ${i}/6: not ready yet, retrying in 5s..."
  sleep 5
done

error "App did not respond. Check: kubectl get pods -n ${NAMESPACE}"
