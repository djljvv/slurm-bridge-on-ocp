#!/bin/bash
set -euo pipefail

###############################################################################
# Deploy Slurm Bridge on OpenShift
#
# Installs the Slurm Bridge Helm chart and required supporting resources:
#   1. RBAC patch for slurm-operator (known OCP bug fix — Token controller
#      can't create its output Secret without this)
#   2. JWT Token CR (Bridge authenticates to Slurm via slurmrestd)
#   3. Slurm Bridge (admission controller + scheduler + controllers)
#   4. RBAC patch for slurm-bridge-scheduler (known OCP bug fix — may be
#      resolved in v1.1.1+)
#   5. Node labels (marks worker nodes as available for Slurm scheduling)
#
# Bridge is installed into the same namespace as the Slurm cluster (default:
# "slurm"), NOT the Slinky operator's namespace. This is required: the Token
# CR's jwtKeyRef looks up the "slurm-auth-jwt" secret in its own namespace,
# and that secret is created by the Slurm Helm chart in the cluster namespace.
# Installing Bridge into the operator namespace (e.g. "slinky") leaves the
# Token controller unable to find the JWT secret, so it never creates the
# "slurm-bridge-token" secret and Bridge pods fail with
# "secret not found".
#
# The Bridge admission controller watches namespaces labeled:
#   managed-by-slurm: "true"
# Pods created in those namespaces are intercepted and scheduled via Slurm.
#
# Usage:
#   ./scripts/deploy-bridge.sh
#   ./scripts/deploy-bridge.sh --namespace slurm --node-count 3
#   ./scripts/deploy-bridge.sh --teardown
###############################################################################

NAMESPACE="${NAMESPACE:-slurm}"
NODE_COUNT="${NODE_COUNT:-3}"
TEARDOWN=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --operator-ns) NAMESPACE="$2"; shift 2 ;;  # deprecated alias, kept for compatibility
    --node-count)  NODE_COUNT="$2"; shift 2 ;;
    --teardown)    TEARDOWN=true; shift ;;
    --help|-h) sed -n '3,32p' "$0" | sed 's/^# \?//'; exit 0 ;;
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
  helm uninstall slurm-bridge -n "$NAMESPACE" 2>/dev/null && log "Bridge Helm release removed" || warn "Bridge not installed via Helm"
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
# Step 1: RBAC patch for the Slinky operator (OCP bug workaround)
#
# The Token controller (part of slurm-operator) creates a Secret owned by
# the Token CR with blockOwnerDeletion=true. Kubernetes requires "update"
# permission on the finalizers subresource of the owner's *kind* before it
# will allow that — but the operator's default ClusterRole only grants
# plain "secrets" permissions, not "secrets/finalizers". Without this patch,
# the Token controller fails every reconcile with:
#   "cannot set blockOwnerDeletion if an ownerReference refers to a
#    resource you can't set finalizers on"
# and never creates the "slurm-bridge-token" secret, so all Bridge pods
# stay stuck with "secret not found". Patching before the Token CR is
# applied lets the very first reconcile succeed instead of waiting through
# several backoff cycles.
# ---------------------------------------------------------------------------
section "Applying operator RBAC patch"
log "Patching slurm-operator ClusterRole (adds secrets/finalizers, OCP workaround)..."
oc patch clusterrole slurm-operator \
  --type='json' \
  -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["secrets/finalizers"],"verbs":["update"]}}]' \
  2>/dev/null && log "RBAC patch applied" || warn "RBAC patch failed or already applied — check if fix is in current operator version"

# ---------------------------------------------------------------------------
# Step 2: Token CR (Bridge → Slurm REST API auth)
# ---------------------------------------------------------------------------
section "Creating Slurm Bridge Token"
log "Applying token CR (JWT auth for Bridge → slurmrestd)..."
oc apply -f "${REPO_ROOT}/configs/token.yaml"
log "Token CR applied"

# ---------------------------------------------------------------------------
# Step 3: Install Bridge via Helm
# ---------------------------------------------------------------------------
section "Installing Slurm Bridge"
log "Installing slurm-bridge Helm chart (namespace: $NAMESPACE)..."
helm upgrade --install slurm-bridge \
  oci://ghcr.io/slinkyproject/charts/slurm-bridge \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "${REPO_ROOT}/configs/slurm-bridge-values.yaml" || {
    error "Failed to install Slurm Bridge"
    exit 1
  }

log "Waiting for Bridge components..."
oc rollout status deployment/slurm-bridge-admission    -n "$NAMESPACE" --timeout=300s
oc rollout status deployment/slurm-bridge-controllers  -n "$NAMESPACE" --timeout=300s
oc rollout status deployment/slurm-bridge-scheduler    -n "$NAMESPACE" --timeout=300s

# ---------------------------------------------------------------------------
# Step 4: RBAC patch for the Bridge scheduler (OCP bug workaround — fix expected in v1.1.1+)
# ---------------------------------------------------------------------------
section "Applying Bridge scheduler RBAC patch"
log "Patching slurm-bridge-scheduler ClusterRole (OCP workaround)..."
oc patch clusterrole slurm-bridge-scheduler \
  --type='json' \
  -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["pods/finalizers"],"verbs":["update","patch"]}}]' \
  2>/dev/null && log "RBAC patch applied" || warn "RBAC patch failed or already applied — check if fix is in current Bridge version"

# ---------------------------------------------------------------------------
# Step 5: Label worker nodes for Slurm scheduling
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

gpu_count=0
for node in $(oc get nodes -o jsonpath='{range .items[?(@.status.capacity.nvidia\.com/gpu)]}{.metadata.name}{"\n"}{end}'); do
  log "Labeling GPU node: $node"
  oc patch "node/$node" \
    -p '{"metadata":{"labels":{"scheduler.slinky.slurm.net/external-node":"true"},"annotations":{"scheduler.slinky.slurm.net/external-node-partitions":"all"}}}' \
    --type=merge
  gpu_count=$((gpu_count + 1))
done

if [ "$gpu_count" -gt 0 ]; then
  log "Labeled $gpu_count GPU node(s) for Slurm"
else
  log "No GPU nodes found — GPU workloads will not be schedulable"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
section "Slurm Bridge deployed"
log "Bridge components in namespace: $NAMESPACE"
oc get pods -n "$NAMESPACE" | grep -E "^NAME|bridge" || true
echo ""
log "To submit jobs through Bridge, label your workload namespace:"
log "  oc label namespace <namespace> managed-by-slurm=true"
