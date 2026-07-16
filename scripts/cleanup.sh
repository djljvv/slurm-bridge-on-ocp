#!/bin/bash
set -euo pipefail

###############################################################################
# Cleanup — Remove Slurm Bridge on OCP
#
# By default: removes the Slurm cluster and Bridge (keeps operator).
# With --remove-operator: full uninstall including operator, CRDs, namespaces.
#
# Usage:
#   ./scripts/cleanup.sh                    # Remove cluster + bridge
#   ./scripts/cleanup.sh --remove-operator  # Full uninstall
###############################################################################

NAMESPACE="${NAMESPACE:-slurm}"
OPERATOR_NS="${OPERATOR_NS:-slinky}"
REMOVE_OPERATOR=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)       NAMESPACE="$2"; shift 2 ;;
    --operator-ns)     OPERATOR_NS="$2"; shift 2 ;;
    --remove-operator) REMOVE_OPERATOR=true; shift ;;
    --help|-h) sed -n '3,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log()     { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; echo ""; }
run_ignore() { "$@" 2>/dev/null || true; }

section "Slurm Bridge on OCP — Cleanup"
log "Namespace: $NAMESPACE | Operator ns: $OPERATOR_NS | Remove operator: $REMOVE_OPERATOR"

# ---------------------------------------------------------------------------
# 1. Bridge (lives in the Slurm cluster namespace, not the operator namespace)
# ---------------------------------------------------------------------------
section "Removing Slurm Bridge"
"${SCRIPT_DIR}/deploy-bridge.sh" --namespace "$NAMESPACE" --teardown 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1b. Remove Bridge node labels, annotations, and taints
# ---------------------------------------------------------------------------
section "Removing Bridge node labels and taints"
for node in $(oc get nodes -l scheduler.slinky.slurm.net/external-node=true -o name 2>/dev/null); do
  log "Cleaning: $node"
  run_ignore oc label "$node" scheduler.slinky.slurm.net/external-node-
  run_ignore oc annotate "$node" scheduler.slinky.slurm.net/external-node-partitions-
  run_ignore oc adm taint node "$node" slinky.slurm.net/managed-node-
done

# ---------------------------------------------------------------------------
# 2. Slurm cluster
# ---------------------------------------------------------------------------
section "Removing Slurm cluster"
if oc get namespace "$NAMESPACE" &>/dev/null; then
  if command -v helm &>/dev/null; then
    helm uninstall slurm -n "$NAMESPACE" 2>/dev/null && log "Helm release 'slurm' removed" || \
      warn "Helm uninstall failed — removing resources directly"
  fi
  run_ignore oc delete statefulset,deployment,replicaset,pod --all -n "$NAMESPACE" --ignore-not-found --timeout=60s
  run_ignore oc delete svc,configmap,secret,pvc --all -n "$NAMESPACE" --ignore-not-found --timeout=60s
  run_ignore oc delete controller,nodeset,restapi --all -n "$NAMESPACE" --ignore-not-found --timeout=60s
  run_ignore oc adm policy remove-scc-from-user anyuid -z default -n "$NAMESPACE"
  run_ignore oc adm policy remove-scc-from-user privileged -z default -n "$NAMESPACE"
  oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s 2>/dev/null || \
    warn "Namespace $NAMESPACE may still be terminating"
else
  warn "Namespace $NAMESPACE not found — skipping"
fi

# ---------------------------------------------------------------------------
# 3. Operator (optional)
# ---------------------------------------------------------------------------
if [ "$REMOVE_OPERATOR" = true ]; then
  section "Removing Slurm Operator"
  if command -v helm &>/dev/null; then
    helm uninstall slurm-operator -n "$OPERATOR_NS" 2>/dev/null || true
    helm uninstall slurm-operator-crds -n "$OPERATOR_NS" 2>/dev/null || true
  fi
  run_ignore oc delete deployment,statefulset,pod --all -n "$OPERATOR_NS" --ignore-not-found --timeout=60s
  oc delete namespace "$OPERATOR_NS" --ignore-not-found --timeout=120s 2>/dev/null || \
    warn "Namespace $OPERATOR_NS may still be terminating"

  log "Removing Slinky CRDs..."
  for crd in controllers.slinky.slurm.net nodesets.slinky.slurm.net \
              restapis.slinky.slurm.net tokens.slinky.slurm.net \
              loginsets.slinky.slurm.net accountings.slinky.slurm.net; do
    oc delete crd "$crd" --ignore-not-found --timeout=60s 2>/dev/null && \
      log "Deleted CRD: $crd" || true
  done
fi

section "Cleanup complete"
if [ "$REMOVE_OPERATOR" = false ]; then
  log "Operator kept. To also remove operator: ./scripts/cleanup.sh --remove-operator"
fi
log "Redeploy: ./scripts/deploy.sh"
