#!/bin/bash
set -euo pipefail

###############################################################################
# Deploy Slurm NodeSet Autoscaler
#
# Deploys the queue-driven autoscaler loop that:
#   - Scales UP when pending jobs need more nodes than are available
#   - Scales DOWN after an idle period with no pending/running jobs
#
# Any sbatch job (manual, via Bridge, via notebook) triggers scale-up.
# No launcher code needed — scaling is purely queue-driven.
#
# Usage:
#   ./scripts/deploy-autoscale.sh              # Deploy
#   ./scripts/deploy-autoscale.sh --teardown   # Remove
#   NAMESPACE=my-slurm ./scripts/deploy-autoscale.sh
###############################################################################

NAMESPACE="${NAMESPACE:-slurm}"
TEARDOWN=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --teardown)    TEARDOWN=true; shift ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --help|-h) sed -n '3,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; echo ""; }

if [ "$TEARDOWN" = true ]; then
  section "Removing autoscaler"
  oc delete -f "${REPO_ROOT}/configs/slurm-autoscaler.yaml" --ignore-not-found
  oc delete configmap slurm-autoscaler-script -n "$NAMESPACE" --ignore-not-found
  log "Autoscaler removed"
  exit 0
fi

section "Deploying autoscaler (queue-driven scale-up/down)"

log "Creating ConfigMap 'slurm-autoscaler-script'..."
oc create configmap slurm-autoscaler-script -n "$NAMESPACE" \
  --from-file=autoscaler.sh="${SCRIPT_DIR}/autoscaler-loop.sh" \
  --dry-run=client -o yaml | oc apply -f -

log "Applying autoscaler RBAC and Deployment..."
oc apply -f "${REPO_ROOT}/configs/slurm-autoscaler.yaml"

log "Granting privileged SCC to autoscaler SA (required to exec into controller pod)..."
oc adm policy add-scc-to-user privileged -z slurm-autoscaler -n "$NAMESPACE" 2>/dev/null || true

log "Waiting for autoscaler pod..."
waited=0
while [ $waited -lt 60 ]; do
  if oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=slurm-autoscaler \
      --no-headers 2>/dev/null | grep -qE "Running|ContainerCreating"; then
    log "Autoscaler pod is starting"
    break
  fi
  sleep 3
  waited=$((waited + 3))
done

section "Autoscaler deployed"
echo "  Submit any sbatch job — the autoscaler scales up automatically."
echo "  After ${SCALE_DOWN_DELAY:-300}s idle, it scales back to minimum."
echo ""
echo "  Monitor: oc logs -n $NAMESPACE -l app.kubernetes.io/name=slurm-autoscaler -f"
