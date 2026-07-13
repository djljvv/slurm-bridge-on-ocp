#!/bin/bash
set -euo pipefail

###############################################################################
# Slurm Bridge on OCP — Master Deploy Script
#
# Deploys the full stack in order:
#   1. Slurm Operator (Slinky CRDs + operator)
#   2. Slurm Cluster (controller + nodeset + REST API via Helm)
#   3. Slurm Bridge (token + admission controller + scheduler + node labels)
#   4. Autoscaler (queue-driven scale-up/down watchdog)
#
# Usage:
#   ./scripts/deploy.sh
#   ./scripts/deploy.sh --namespace slurm --operator-ns slinky
#   ./scripts/deploy.sh --skip-operator   # if operator already installed
###############################################################################

NAMESPACE="${NAMESPACE:-slurm}"
OPERATOR_NS="${OPERATOR_NS:-slinky}"
SKIP_OPERATOR=false
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --operator-ns)  OPERATOR_NS="$2"; shift 2 ;;
    --skip-operator) SKIP_OPERATOR=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --help|-h) sed -n '3,13p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
section() { echo ""; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${BLUE}  $1${NC}"; \
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo ""; }

section "Slurm Bridge on OCP — Deployment"
log "Namespace:    $NAMESPACE"
log "Operator ns:  $OPERATOR_NS"
log "Skip operator: $SKIP_OPERATOR"
echo ""

if [ "$DRY_RUN" = true ]; then
  log "[DRY RUN] Would run the following steps:"
  log "  1. deploy-operator.sh --operator-ns $OPERATOR_NS"
  log "  2. deploy-slurm.sh --namespace $NAMESPACE"
  log "  3. deploy-bridge.sh --namespace $NAMESPACE"
  log "  4. deploy-autoscale.sh (namespace: $NAMESPACE)"
  exit 0
fi

# Step 1: Operator
if [ "$SKIP_OPERATOR" = false ]; then
  section "Step 1/4 — Slurm Operator"
  OPERATOR_NS="$OPERATOR_NS" "${SCRIPT_DIR}/deploy-operator.sh" --operator-ns "$OPERATOR_NS"
else
  log "Skipping operator installation (--skip-operator)"
fi

# Step 2: Slurm cluster
section "Step 2/4 — Slurm Cluster"
NAMESPACE="$NAMESPACE" OPERATOR_NS="$OPERATOR_NS" "${SCRIPT_DIR}/deploy-slurm.sh" \
  --namespace "$NAMESPACE" --operator-ns "$OPERATOR_NS"

# Step 3: Slurm Bridge (installed into the Slurm cluster namespace — Bridge's
# Token CR needs the JWT secret that lives there, not the operator namespace)
section "Step 3/4 — Slurm Bridge"
NAMESPACE="$NAMESPACE" "${SCRIPT_DIR}/deploy-bridge.sh" --namespace "$NAMESPACE"

# Step 4: Autoscaler
section "Step 4/4 — Autoscaler"
NAMESPACE="$NAMESPACE" "${SCRIPT_DIR}/deploy-autoscale.sh" --namespace "$NAMESPACE"

# Done
section "Deployment Complete"
log "Slurm cluster:    oc get pods -n $NAMESPACE"
log "Bridge:           oc get pods -n $NAMESPACE | grep bridge"
log "Autoscaler logs:  oc logs -n $NAMESPACE -l app.kubernetes.io/name=slurm-autoscaler -f"
echo ""
log "Test cluster:"
log "  ./scripts/test-slurm.sh --namespace $NAMESPACE"
echo ""
log "Submit a job (autoscaler will scale up automatically):"
log "  CTRL=\$(oc get pods -n $NAMESPACE -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')"
log "  oc exec -n $NAMESPACE \$CTRL -c slurmctld -- sbatch --nodes=2 --wrap=\"hostname\""
