#!/bin/bash
set -euo pipefail

###############################################################################
# Deploy Slurm Cluster via Helm (Controller + NodeSet + REST API)
#
# Uses the Slinky Helm chart which creates:
#   - slurmctld StatefulSet (controller)
#   - slurmd NodeSet pods (workers, starts at 0 replicas)
#   - slurmrestd Deployment (REST API required by Slurm Bridge)
#
# Usage:
#   ./scripts/deploy-slurm.sh
#   ./scripts/deploy-slurm.sh --namespace slurm --operator-ns slinky
###############################################################################

NAMESPACE="${NAMESPACE:-slurm}"
OPERATOR_NS="${OPERATOR_NS:-slinky}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --operator-ns) OPERATOR_NS="$2"; shift 2 ;;
    --help|-h) sed -n '3,9p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

section "Deploying Slurm cluster (namespace: $NAMESPACE)"

# Create namespace and configure security
oc create namespace "$NAMESPACE" 2>/dev/null || true

log "Granting anyuid SCC to default service account..."
# NOTE: add-scc-to-user is idempotent — it does not error out if the grant
# already exists, so a non-zero exit here means a REAL failure (bad RBAC
# permissions, a transient API error, etc.), not "already granted". Treating
# failures as benign previously masked a live failure (during dev/testing,
# these calls silently failed and pods spent minutes stuck in SCC-forbidden
# errors before anyone noticed the grants had never actually applied) — fail
# loudly instead so it's caught immediately, since the controller/worker pods
# cannot schedule at all without these.
if ! oc adm policy add-scc-to-user anyuid -z default -n "$NAMESPACE"; then
  error "Failed to grant anyuid SCC — pods will be stuck in SCC-forbidden errors without it. Check permissions and retry."
  exit 1
fi

# slurmd requires privileged mode + BPF/NET_ADMIN/SYS_ADMIN capabilities
# (cgroup + process/network management). Without this, NodeSet pods
# ("slurm-worker-slinky-N") are rejected by OpenShift's SCC admission with
# "unable to validate against any security context constraint" and the
# NodeSet can never scale above 0 replicas — anyuid alone is not enough.
log "Granting privileged SCC to default service account (required by slurmd)..."
if ! oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE"; then
  error "Failed to grant privileged SCC — pods will be stuck in SCC-forbidden errors without it. Check permissions and retry."
  exit 1
fi

# Install Slurm via Helm (includes controller, nodeset, restapi)
log "Installing Slurm via Helm chart (version 1.2.0)..."
helm upgrade --install slurm \
  oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --version 1.2.0 \
  -f "${REPO_ROOT}/configs/slurm-values.yaml" || {
    error "Failed to deploy Slurm via Helm"
    exit 1
  }

# Wait for controller
section "Waiting for Slurm controller"
log "Waiting for slurm-controller StatefulSet..."
while ! oc get statefulset/slurm-controller -n "$NAMESPACE" &>/dev/null; do
  sleep 2
done
oc rollout status statefulset/slurm-controller -n "$NAMESPACE" --timeout=300s || {
  warn "Controller did not reach ready state within timeout"
  warn "Check: oc get pods -n $NAMESPACE"
}

# Wait for REST API (required by Bridge)
section "Waiting for Slurm REST API"
log "Waiting for slurm-restapi Deployment..."
while ! oc get deployment/slurm-restapi -n "$NAMESPACE" &>/dev/null; do
  sleep 2
done
oc rollout status deployment/slurm-restapi -n "$NAMESPACE" --timeout=300s || {
  warn "REST API did not reach ready state within timeout"
  warn "Bridge requires the REST API — check: oc get pods -n $NAMESPACE"
}

section "Slurm cluster deployed"
log "Namespace: $NAMESPACE"
oc get pods -n "$NAMESPACE"
echo ""
log "Verify with:"
log "  oc exec -n $NAMESPACE \$(oc get pods -n $NAMESPACE -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}') -c slurmctld -- sinfo"
