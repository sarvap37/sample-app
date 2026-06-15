#!/usr/bin/env bash
# Phase 3 setup: install ArgoCD in Kind, configure SSH repo access, apply Application.
# Run once after phase2-setup.sh. Idempotent on re-runs.
set -euo pipefail

ARGOCD_NS="argocd"
REPO_URL="git@github.com:sarvap37/sample-app.git"
APP_NAME="hello-world-app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve SSH key: prefer id_ed25519, fall back to id_rsa, or use SSH_KEY_PATH env
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
if [[ -z "${SSH_KEY_PATH}" ]]; then
  for candidate in ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
    if [[ -f "${candidate}" ]]; then
      SSH_KEY_PATH="${candidate}"
      break
    fi
  done
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
section "Prerequisites"
for tool in kubectl argocd; do
  command -v "$tool" &>/dev/null || error "'$tool' not found in PATH"
done
kubectl config current-context | grep -q "kind-hello-world-cluster" \
  || error "kubectl context is not kind-hello-world-cluster — run phase2-setup.sh first"
[[ -f "${SSH_KEY_PATH}" ]] \
  || error "SSH key not found. Set SSH_KEY_PATH=/path/to/key or generate one:
  ssh-keygen -t ed25519 -C 'your@email.com'"
info "Using SSH key: ${SSH_KEY_PATH}"
info "Prerequisites OK."

# ── 2. Install ArgoCD ─────────────────────────────────────────────────────────
section "Installing ArgoCD"
kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f -

ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
kubectl apply -n "${ARGOCD_NS}" -f "${ARGOCD_MANIFEST}"

info "Waiting for ArgoCD server to be ready (up to 5 min)..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n "${ARGOCD_NS}"
info "ArgoCD installed."

# ── 3. Configure SSH repo credential ─────────────────────────────────────────
section "Configuring GitHub SSH access"
info "Scanning github.com host key..."
ssh-keyscan github.com 2>/dev/null > /tmp/argocd_known_hosts

kubectl create secret generic argocd-repo-github \
  -n "${ARGOCD_NS}" \
  --from-literal=type=git \
  --from-literal=url="${REPO_URL}" \
  --from-file=sshPrivateKey="${SSH_KEY_PATH}" \
  --from-file=known_hosts=/tmp/argocd_known_hosts \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret argocd-repo-github -n "${ARGOCD_NS}" \
  argocd.argoproj.io/secret-type=repository --overwrite

rm -f /tmp/argocd_known_hosts
info "SSH repo credential configured. (Key stored only in-cluster, not in Git.)"

# ── 4. Apply ArgoCD Application ───────────────────────────────────────────────
section "Applying ArgoCD Application"
kubectl apply -f "${REPO_ROOT}/argocd/application.yaml"
info "Application '${APP_NAME}' created."

# ── 5. Initial sync ───────────────────────────────────────────────────────────
section "Initial sync"
info "Triggering sync via argocd CLI (port-forward handled automatically)..."
argocd app sync "${APP_NAME}" \
  --port-forward \
  --port-forward-namespace "${ARGOCD_NS}" \
  --force \
  --timeout 120

info "Waiting for app to reach Healthy state..."
argocd app wait "${APP_NAME}" \
  --port-forward \
  --port-forward-namespace "${ARGOCD_NS}" \
  --health \
  --timeout 120

# ── 6. Verify ─────────────────────────────────────────────────────────────────
section "Verification"
for i in {1..8}; do
  RESPONSE=$(curl -s --max-time 3 http://localhost:30000 2>/dev/null || true)
  if [[ "${RESPONSE}" == *"Hello World"* ]]; then
    echo ""
    echo -e "${GREEN}✓ Phase 3 setup complete!${NC}"
    echo ""
    echo "  App URL    : http://localhost:30000"
    echo "  ArgoCD UI  : https://localhost:8080  (run: kubectl port-forward svc/argocd-server -n argocd 8080:443)"
    echo ""
    ARGOCD_PASS=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" | base64 --decode)
    echo "  ArgoCD login:"
    echo "    username : admin"
    echo "    password : ${ARGOCD_PASS}"
    echo ""
    echo "  GitOps CI  : bash scripts/ci-local.sh   # test → build → push → git commit → argocd sync"
    echo "  App status : argocd app get ${APP_NAME} --port-forward --port-forward-namespace argocd"
    echo ""
    exit 0
  fi
  warn "Attempt ${i}/8: not ready, retrying in 5s..."
  sleep 5
done

error "App did not respond. Check:
  kubectl get pods -n default
  argocd app get ${APP_NAME} --port-forward --port-forward-namespace argocd"
