#!/bin/bash
set -euo pipefail

###############################################################################
# Deploy Slurm Bridge on OpenShift
#
# Installs the Slurm Bridge Helm chart and required supporting resources:
#   1. JWT Token CR (Bridge authenticates to Slurm via slurmrestd)
#   2. Slurm Bridge (admission controller + scheduler + controllers)
#   3. RBAC patch (known OCP bug fix — may be resolved in v1.1.1+)
#   4. Node labels (marks worker nodes as available for Slurm scheduling)
#
# The Bridge admission controller watches namespaces labeled:
#   managed-by-slurm: "true"
# Pods created in those namespaces are intercepted and scheduled via Slurm.
#
# Usage:
#   ./scripts/deploy-bridge.sh
#   ./scripts/deploy-bridge.sh --operator-ns slinky --node-count 3
#   ./scripts/deploy-bridge.sh --teardown
###############################################################################

OPERATOR_NS="${OPERATOR_NS:-slinky}"
NODE_COUNT="${NODE_COUNT:-3}"
TEARDOWN=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --operator-ns) OPERATOR_NS="$2"; shift 2 ;;
    --node-count)  NODE_COUNT="$2"; shift 2 ;;
    --teardown)    TEARDOWN=true; shift ;;
    --help|-h) sed -n '3,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
if [ "$TEARDOWN" = true ]; then
  section "Removing Slurm Bridge"
  helm uninstall slurm-bridge -n "$OPERATOR_NS" 2>/dev/null && log "Bridge Helm release removed" || warn "Bridge not installed via Helm"
  oc delete -f "${REPO_ROOT}/configs/token.yaml" --ignore-not-found 2>/dev/null || true
  log "Removing node labels..."
  for node in $(oc get nodes -o name -l node-role.kubernetes.io/worker=''); do
    oc patch "$node" -p '{"metadata":{"labels":{"scheduler.slinky.slurm.net/external-node":null},"annotations":{"scheduler.slinky.slurm.net/external-node-partitions":null}}}' \
      --type=merge 2>/dev/null || true
  done
  log "Bridge removed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Token CR (Bridge → Slurm REST API auth)
# ---------------------------------------------------------------------------
section "Creating Slurm Bridge Token"
log "Applying token CR (JWT auth for Bridge → slurmrestd)..."
oc apply -f "${REPO_ROOT}/configs/token.yaml"
log "Token CR applied"

# ---------------------------------------------------------------------------
# Step 2: Install Bridge via Helm
# ---------------------------------------------------------------------------
section "Installing Slurm Bridge"
log "Installing slurm-bridge Helm chart (namespace: $OPERATOR_NS)..."
helm upgrade --install slurm-bridge \
  oci://ghcr.io/slinkyproject/charts/slurm-bridge \
  --namespace "$OPERATOR_NS" \
  --create-namespace \
  -f "${REPO_ROOT}/configs/slurm-bridge-values.yaml" || {
    error "Failed to install Slurm Bridge"
    exit 1
  }

log "Waiting for Bridge components..."
oc rollout status deployment/slurm-bridge-admission    -n "$OPERATOR_NS" --timeout=300s
oc rollout status deployment/slurm-bridge-controllers  -n "$OPERATOR_NS" --timeout=300s
oc rollout status deployment/slurm-bridge-scheduler    -n "$OPERATOR_NS" --timeout=300s

# ---------------------------------------------------------------------------
# Step 3: RBAC patch (OCP bug workaround — fix expected in v1.1.1+)
# ---------------------------------------------------------------------------
section "Applying RBAC patch"
log "Patching slurm-bridge-scheduler ClusterRole (OCP workaround)..."
oc patch clusterrole slurm-bridge-scheduler \
  --type='json' \
  -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["pods/finalizers"],"verbs":["update","patch"]}}]' \
  2>/dev/null && log "RBAC patch applied" || warn "RBAC patch failed or already applied — check if fix is in current Bridge version"

# ---------------------------------------------------------------------------
# Step 4: Label worker nodes for Slurm scheduling
# ---------------------------------------------------------------------------
section "Labeling worker nodes"
log "Labeling up to $NODE_COUNT worker nodes for Slurm Bridge scheduling..."

count=0
for node in $(oc get nodes -o name -l node-role.kubernetes.io/worker=''); do
  log "Labeling: $node"
  oc patch "$node" \
    -p '{"metadata":{"labels":{"scheduler.slinky.slurm.net/external-node":"true"},"annotations":{"scheduler.slinky.slurm.net/external-node-partitions":"all"}}}' \
    --type=merge
  count=$((count + 1))
  if [ "$count" -ge "$NODE_COUNT" ]; then
    break
  fi
done

log "Labeled $count worker node(s) for Slurm"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
section "Slurm Bridge deployed"
log "Bridge components in namespace: $OPERATOR_NS"
oc get pods -n "$OPERATOR_NS" -l app.kubernetes.io/name=slurm-bridge 2>/dev/null || \
  oc get pods -n "$OPERATOR_NS" | grep bridge || true
echo ""
log "To submit jobs through Bridge, label your workload namespace:"
log "  oc label namespace <namespace> managed-by-slurm=true"
