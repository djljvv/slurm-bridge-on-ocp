#!/bin/bash
set -euo pipefail

###############################################################################
# Deploy Slurm Operator (Slinky) — CRDs + Operator
#
# Usage:
#   ./scripts/deploy-operator.sh
#   ./scripts/deploy-operator.sh --operator-ns slinky
#   ./scripts/deploy-operator.sh --skip-if-installed
###############################################################################

OPERATOR_NS="${OPERATOR_NS:-slinky}"
SKIP_IF_INSTALLED=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --operator-ns)  OPERATOR_NS="$2"; shift 2 ;;
    --skip-if-installed) SKIP_IF_INSTALLED=true; shift ;;
    --help|-h) sed -n '3,8p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
error()   { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"; }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; echo ""; }

check_prerequisites() {
  if ! command -v oc &>/dev/null; then
    error "oc CLI not found"; exit 1
  fi
  if ! command -v helm &>/dev/null; then
    error "helm not found"; exit 1
  fi
  if ! oc whoami &>/dev/null; then
    error "Not logged in to OpenShift. Run: oc login"; exit 1
  fi
}

section "Checking prerequisites"
check_prerequisites
log "oc: $(oc whoami) @ $(oc whoami --show-server)"

# ---------------------------------------------------------------------------
# Check if already installed
# ---------------------------------------------------------------------------
section "Checking existing installation"

OPERATOR_RUNNING=false
if oc get pods -n openshift-operators -l app.kubernetes.io/name=slurm-operator \
    --no-headers 2>/dev/null | grep -q Running; then
  log "Slurm Operator already running in openshift-operators (OperatorHub)"
  OPERATOR_RUNNING=true
elif oc get pods -n "$OPERATOR_NS" -l app.kubernetes.io/name=slurm-operator \
    --no-headers 2>/dev/null | grep -q Running; then
  log "Slurm Operator already running in $OPERATOR_NS (Helm)"
  OPERATOR_RUNNING=true
fi

if [ "$OPERATOR_RUNNING" = true ] && [ "$SKIP_IF_INSTALLED" = true ]; then
  log "Operator already installed — skipping"
  exit 0
fi

# ---------------------------------------------------------------------------
# Install CRDs
# ---------------------------------------------------------------------------
section "Installing Slurm Operator CRDs"

if oc get crd controllers.slinky.slurm.net &>/dev/null; then
  log "CRDs already exist — skipping CRD install"
else
  log "Installing CRDs via Helm..."
  local_err=""
  if ! local_err=$(helm upgrade --install slurm-operator-crds \
      oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
      --namespace "$OPERATOR_NS" \
      --create-namespace \
      --server-side=false 2>&1); then
    warn "--server-side=false failed: $local_err — retrying without flag"
    helm upgrade --install slurm-operator-crds \
      oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
      --namespace "$OPERATOR_NS" \
      --create-namespace || {
        error "Failed to install Slurm Operator CRDs"
        exit 1
      }
  fi

  log "Waiting for CRDs to register..."
  sleep 5

  if ! oc get crd controllers.slinky.slurm.net &>/dev/null; then
    error "CRD verification failed after install"
    exit 1
  fi
  log "CRDs installed and verified"
fi

# ---------------------------------------------------------------------------
# Install Operator
# ---------------------------------------------------------------------------
section "Installing Slurm Operator"

if [ "$OPERATOR_RUNNING" = true ]; then
  warn "Operator already running — skipping operator install"
else
  log "Installing Slurm Operator via Helm..."
  local_err=""
  if ! local_err=$(helm upgrade --install slurm-operator \
      oci://ghcr.io/slinkyproject/charts/slurm-operator \
      --namespace "$OPERATOR_NS" \
      --create-namespace \
      --server-side=false \
      --wait --timeout 5m 2>&1); then
    warn "--server-side=false failed: $local_err — retrying without flag"
    helm upgrade --install slurm-operator \
      oci://ghcr.io/slinkyproject/charts/slurm-operator \
      --namespace "$OPERATOR_NS" \
      --create-namespace \
      --wait --timeout 5m || {
        error "Failed to install Slurm Operator"
        exit 1
      }
  fi

  log "Waiting for operator pod to be ready..."
  oc wait --for=condition=ready pod \
    -l app.kubernetes.io/name=slurm-operator \
    -n "$OPERATOR_NS" \
    --timeout=300s || {
      error "Slurm Operator did not become ready"
      exit 1
    }
fi

section "Slurm Operator ready"
log "Operator namespace: $OPERATOR_NS"
oc get pods -n "$OPERATOR_NS" -l app.kubernetes.io/name=slurm-operator 2>/dev/null || true
