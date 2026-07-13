#!/bin/bash

###############################################################################
# Slurm Cluster Test Script
#
# Comprehensive test script for Slurm cluster on OpenShift
#
# Both modes submit plain `sbatch` jobs, which do not trigger autoscaling from
# zero replicas under this chart's default config (see docs/ARCHITECTURE.md
# #autoscaler for why). Before submitting anything, this script checks for an
# already-running worker pod and, if none exists, scales the NodeSet to 1
# replica itself and waits for it to register. This validates that Slurm job
# submission/scheduling/output retrieval works — it intentionally does not
# test the (currently non-functional) autoscaler reactive scale-up path.
#
# Usage: ./test-slurm.sh [options]
#
# Options:
#   --namespace NAMESPACE    Cluster namespace (default: slurm)
#   --nodeset NODESET        NodeSet name (default: slurm-worker-slinky)
#   --controller-pod POD     Controller pod name (auto-detected if not provided)
#   --quick                  Quick end-to-end test (single job, verify output)
#   --comprehensive          Comprehensive test suite (multiple job types)
#   --help                   Show this help message
#
# Default: Quick test (--quick)
###############################################################################

set -euo pipefail

# Default values
NAMESPACE="slurm"
NODESET="slurm-worker-slinky"
CONTROLLER_POD=""
QUICK_MODE=true
COMPREHENSIVE_MODE=false

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --nodeset)
      NODESET="$2"
      shift 2
      ;;
    --controller-pod)
      CONTROLLER_POD="$2"
      shift 2
      ;;
    --quick)
      QUICK_MODE=true
      COMPREHENSIVE_MODE=false
      shift
      ;;
    --comprehensive)
      QUICK_MODE=false
      COMPREHENSIVE_MODE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --namespace NAMESPACE    Cluster namespace (default: slurm)"
      echo "  --nodeset NODESET        NodeSet name (default: slurm-worker-slinky)"
      echo "  --controller-pod POD     Controller pod name (auto-detected if not provided)"
      echo "  --quick                  Quick end-to-end test (default)"
      echo "  --comprehensive          Comprehensive test suite"
      echo "  --help                   Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
  echo ""
  echo -e "${BLUE}=== $1 ===${NC}"
  echo ""
}

# Ensure at least one slurmd worker is registered before submitting any job.
#
# Direct `sbatch` (what this script uses) does not actually trigger autoscaling
# under this chart's default config: with 0 NodeSet replicas, slurmctld has
# never seen a worker of that type register, so `sbatch` is rejected immediately
# ("Requested node configuration is not available") instead of queuing the job
# `PENDING` for the autoscaler to react to. See docs/ARCHITECTURE.md#autoscaler
# for the full explanation. This function works around that by scaling the
# NodeSet up once, manually, so this test can actually validate that Slurm job
# submission/scheduling/output retrieval works — it does not test autoscaling
# itself (nothing currently does, since autoscaling doesn't trigger from sbatch).
worker_pod_ready() {
  # Counts Running slurmd pods for the NodeSet — more reliable than grepping
  # sinfo node names, since Bridge's "external nodes" (real OCP hostnames like
  # ip-10-0-*.ec2.internal) also show up in sinfo and would false-positive a
  # naive name-based match. Label is app.kubernetes.io/instance=<nodeset> +
  # app.kubernetes.io/name=slurmd (verified against the actual chart output —
  # NOT nodeset.slinky.slurm.net/name, which doesn't exist on these pods).
  oc get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$NODESET,app.kubernetes.io/name=slurmd" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' '
}

ensure_worker_available() {
  log_info "Checking for a registered Slurm worker..."

  if [ "$(worker_pod_ready)" -ge 1 ]; then
    log_info "Worker pod already running — skipping bootstrap"
    return 0
  fi

  local replicas
  replicas=$(oc get nodeset "$NODESET" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  log_warn "No worker pod running yet (NodeSet replicas: $replicas)."
  log_warn "Direct sbatch can't trigger autoscaling from zero (see docs/ARCHITECTURE.md#autoscaler)."
  log_info "Scaling NodeSet '$NODESET' to 1 replica so this test can proceed..."
  oc scale nodeset "$NODESET" -n "$NAMESPACE" --replicas=1

  log_info "Waiting for worker pod to be Running (timeout: 120s)..."
  local waited=0
  while [ "$waited" -lt 120 ]; do
    if [ "$(worker_pod_ready)" -ge 1 ]; then
      break
    fi
    sleep 10
    waited=$((waited + 10))
    log_info "  ...still waiting for pod (${waited}s elapsed)"
  done

  if [ "$(worker_pod_ready)" -lt 1 ]; then
    log_error "Timed out waiting for worker pod. Job submission will likely fail."
    log_info "Check: oc get pods -n $NAMESPACE -l app.kubernetes.io/instance=$NODESET,app.kubernetes.io/name=slurmd"
    return 1
  fi

  log_info "Waiting for worker to register with slurmctld and reach idle state (timeout: 90s)..."
  waited=0
  while [ "$waited" -lt 90 ]; do
    if oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- \
        sinfo -h -N -o "%T" 2>/dev/null | grep -qE "idle|mix"; then
      log_info "Worker registered and idle."
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
    log_info "  ...still waiting for Slurm registration (${waited}s elapsed)"
  done

  log_error "Worker pod is Running but never registered as idle in Slurm. Job submission may fail."
  return 1
}

# Get controller pod if not provided
if [ -z "$CONTROLLER_POD" ]; then
  log_info "Auto-detecting controller pod..."
  CONTROLLER_POD=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ -z "$CONTROLLER_POD" ]; then
    log_error "Controller pod not found in namespace $NAMESPACE"
    log_info "Please provide pod name: $0 --controller-pod <pod-name> [--namespace <ns>]"
    exit 1
  fi
fi

log_info "Using controller pod: $CONTROLLER_POD"
log_info "Namespace: $NAMESPACE"
echo ""

# Both modes submit sbatch jobs that need an already-registered worker (see
# ensure_worker_available's comment above for why this can't just rely on the
# autoscaler).
ensure_worker_available
echo ""

# Quick test mode (default)
if [ "$QUICK_MODE" = true ]; then
  log_section "Quick End-to-End Test"
  
  log_info "1. Checking cluster status..."
  oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sinfo
  echo ""
  
  log_info "2. Checking available nodes..."
  oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- scontrol show nodes | head -20
  echo ""
  
  log_info "3. Submitting test job..."
  JOB_OUTPUT=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sbatch --output=/tmp/quick-test.out --wrap="echo 'Quick test job' && hostname && date && echo 'Job completed successfully'")
  echo "$JOB_OUTPUT"
  JOB_ID=$(echo "$JOB_OUTPUT" | awk '/Submitted batch job/{print $4}')
  log_info "Job ID: $JOB_ID"
  echo ""
  
  log_info "4. Waiting for job to complete (5 seconds)..."
  sleep 5
  
  log_info "5. Checking job queue..."
  oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- squeue
  echo ""
  
  log_info "6. Checking detailed job status..."
  oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- scontrol show job "$JOB_ID" 2>/dev/null | grep -E "(JobId|JobState|ExitCode|NodeList|StdOut|SubmitTime|StartTime|EndTime)" || log_warn "Job may have been purged from memory (check output file instead)"
  echo ""
  
  log_info "7. Finding which compute node ran the job..."
  # Anchored on a preceding whitespace/line-start so this only matches the
  # "NodeList=" field itself — a plain `grep "NodeList="` also matches
  # "ReqNodeList=" and "ExcNodeList=" on the same scontrol output, which
  # corrupted NODE_LIST with extra garbage lines/values.
  NODE_LIST=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- scontrol show job "$JOB_ID" 2>/dev/null \
    | grep -oE '(^|[[:space:]])NodeList=[^ ]*' | head -1 | awk -F= '{print $2}')
  if [ -n "$NODE_LIST" ]; then
    log_info "Job ran on: $NODE_LIST"
    # Derive pod name from Slurm node name (slinky-N → slurm-worker-slinky-N)
    FIRST_NODE=$(echo "$NODE_LIST" | sed 's/\[.*//;s/,.*//')
    COMPUTE_NODE="slurm-worker-${FIRST_NODE}"
  else
    log_warn "Could not determine node, will try first compute node"
    COMPUTE_NODE="slurm-worker-slinky-0"
  fi
  echo ""
  
  log_info "8. Viewing job output..."
  if [ -n "$COMPUTE_NODE" ]; then
    log_info "Checking $COMPUTE_NODE (from NodeList=$NODE_LIST)..."
    oc exec -n "$NAMESPACE" "$COMPUTE_NODE" -c slurmd -- cat /tmp/quick-test.out 2>/dev/null || log_warn "File not found on $COMPUTE_NODE"
  else
    log_info "Trying both compute nodes..."
    if oc exec -n "$NAMESPACE" slurm-worker-slinky-0 -c slurmd -- cat /tmp/quick-test.out 2>/dev/null; then
      echo ""
    elif oc exec -n "$NAMESPACE" slurm-worker-slinky-1 -c slurmd -- cat /tmp/quick-test.out 2>/dev/null; then
      echo ""
    else
      log_warn "Output file not found. Checking for other output files..."
      oc exec -n "$NAMESPACE" slurm-worker-slinky-0 -c slurmd -- ls -la /tmp/*.out 2>/dev/null || log_warn "No output files found on compute-0"
    fi
  fi
  echo ""
  
  log_section "Quick Test Complete"
  
  echo "To submit more jobs, use:"
  echo "  oc exec -n $NAMESPACE $CONTROLLER_POD -c slurmctld -- sbatch --output=/tmp/myjob.out --wrap=\"echo 'My job'\""
  echo ""
  echo "To view job status:"
  echo "  oc exec -n $NAMESPACE $CONTROLLER_POD -c slurmctld -- scontrol show job <JOB_ID>"
  echo ""
  echo "To view job output:"
  echo "  # First, find which node ran the job:"
  echo "  oc exec -n $NAMESPACE $CONTROLLER_POD -c slurmctld -- scontrol show job <JOB_ID> | grep NodeList"
  echo "  # Then view output:"
  echo "  # If NodeList=slinky-0: oc exec -n $NAMESPACE slurm-worker-slinky-0 -c slurmd -- cat /tmp/myjob.out"
  echo "  # If NodeList=slinky-1: oc exec -n $NAMESPACE slurm-worker-slinky-1 -c slurmd -- cat /tmp/myjob.out"
  echo "  # Or try both: oc exec -n $NAMESPACE slurm-worker-slinky-0 -c slurmd -- cat /tmp/myjob.out 2>/dev/null || oc exec -n $NAMESPACE slurm-worker-slinky-1 -c slurmd -- cat /tmp/myjob.out"
fi

# Comprehensive test mode
if [ "$COMPREHENSIVE_MODE" = true ]; then
  log_section "Comprehensive Test Suite"
  
  log_info "Test 1: Simple Hello World job"
  JOB_OUTPUT=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sbatch --wrap="echo 'Hello from Slurm' && hostname && date" 2>&1)
  JOB_ID=$(echo "$JOB_OUTPUT" | awk '/Submitted batch job/{print $4}')
  if [ -n "$JOB_ID" ]; then
    log_info "Job submitted: $JOB_ID"
    sleep 5
    oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- squeue -j "$JOB_ID" || true
  else
    log_warn "Failed to submit job"
  fi
  echo ""
  
  log_info "Test 2: CPU-intensive job"
  JOB_OUTPUT=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sbatch \
    --cpus-per-task=2 \
    --wrap="echo 'CPU test' && nproc && sleep 30" 2>&1)
  JOB_ID=$(echo "$JOB_OUTPUT" | awk '/Submitted batch job/{print $4}')
  if [ -n "$JOB_ID" ]; then
    log_info "Job submitted: $JOB_ID"
    sleep 5
    oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- squeue -j "$JOB_ID" || true
  else
    log_warn "Failed to submit job"
  fi
  echo ""
  
  log_info "Test 3: Memory-intensive job"
  JOB_OUTPUT=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sbatch \
    --mem=2G \
    --wrap="echo 'Memory test' && free -h && sleep 30" 2>&1)
  JOB_ID=$(echo "$JOB_OUTPUT" | awk '/Submitted batch job/{print $4}')
  if [ -n "$JOB_ID" ]; then
    log_info "Job submitted: $JOB_ID"
    sleep 5
    oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- squeue -j "$JOB_ID" || true
  else
    log_warn "Failed to submit job"
  fi
  echo ""
  
  log_info "Test 4: Submitting 5 jobs to test scheduling"
  for i in {1..5}; do
    JOB_OUTPUT=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sbatch \
      --wrap="echo 'Job $i' && sleep 60" 2>&1)
    JOB_ID=$(echo "$JOB_OUTPUT" | awk '/Submitted batch job/{print $4}')
    if [ -n "$JOB_ID" ]; then
      log_info "Job $i submitted: $JOB_ID"
    fi
  done
  
  sleep 5
  log_info "Current queue status:"
  oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- squeue
  echo ""
  
  log_info "Test 5: Job with dependencies"
  JOB_OUTPUT=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sbatch --wrap="echo 'Job 1' && sleep 10" 2>&1)
  JOB1=$(echo "$JOB_OUTPUT" | awk '/Submitted batch job/{print $4}')
  if [ -n "$JOB1" ]; then
    log_info "First job submitted: $JOB1"
    JOB2_OUTPUT=$(oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sbatch --dependency=afterok:"$JOB1" --wrap="echo 'Job 2 (depends on $JOB1)'" 2>&1)
    JOB2=$(echo "$JOB2_OUTPUT" | awk '/Submitted batch job/{print $4}')
    if [ -n "$JOB2" ]; then
      log_info "Dependent job submitted: $JOB2"
      sleep 5
      oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- squeue -j "$JOB1,$JOB2" || true
    fi
  fi
  echo ""
  
  log_info "Cluster status:"
  oc exec -n "$NAMESPACE" "$CONTROLLER_POD" -c slurmctld -- sinfo
  echo ""
  
  log_section "Comprehensive Test Complete"
  
  log_info "All test jobs submitted. Monitor with:"
  echo "  oc exec -n $NAMESPACE $CONTROLLER_POD -c slurmctld -- squeue"
  echo "  oc exec -n $NAMESPACE $CONTROLLER_POD -c slurmctld -- sacct"
fi
