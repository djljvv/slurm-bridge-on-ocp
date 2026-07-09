#!/bin/bash
set -euo pipefail

###############################################################################
# Kueue + Slurm Bridge Demo
#
# Shows the full integration: Kueue admission → Slurm Bridge intercept → Slurm
#
# Quota is set to 200m CPU — each job requests 200m, so Job 2 is held by
# Kueue until Job 1 completes. This demonstrates that Kueue is actually
# controlling admission, not just passing jobs straight through.
#
# Prerequisites:
#   - Slurm Bridge deployed (run ./scripts/deploy.sh first)
#   - Kueue operator installed (OCP 4.21+: OperatorHub → Kueue)
#   - Kueue CR created with BatchJob framework enabled (see README)
#
# Usage:
#   ./demos/kueue_demo.sh
#   ./demos/kueue_demo.sh --cleanup
#   ./demos/kueue_demo.sh --slurm-ns slurm --operator-ns slinky
###############################################################################

SLURM_NS="${SLURM_NS:-slurm}"
OPERATOR_NS="${OPERATOR_NS:-slinky}"
DEMO_NS="slurm-kueue-demo"
QUEUE_NAME="slurm-queue"
CLEANUP=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --slurm-ns)   SLURM_NS="$2"; shift 2 ;;
    --operator-ns) OPERATOR_NS="$2"; shift 2 ;;
    --cleanup)    CLEANUP=true; shift ;;
    --help|-h)
      sed -n '3,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
info()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $*"; }
section() { echo ""; echo -e "${BLUE}━━━ $* ━━━${NC}"; echo ""; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  section "Cleanup"
  log "Removing demo namespace and queue resources..."
  oc delete namespace "$DEMO_NS" --ignore-not-found
  oc delete clusterqueue slurm-cluster-queue --ignore-not-found
  oc delete resourceflavor default-flavor --ignore-not-found
  log "Cleanup complete"
  exit 0
}

if [ "$CLEANUP" = true ]; then
  cleanup
fi

# ---------------------------------------------------------------------------
# Prereq checks
# ---------------------------------------------------------------------------
section "Checking prerequisites"

log "Checking Kueue CRDs..."
if ! oc get crd clusterqueues.kueue.x-k8s.io &>/dev/null; then
  echo ""
  echo "  Kueue CRDs not found. Install the Kueue operator first:"
  echo "    OCP 4.21+: OperatorHub → search 'Kueue' → install"
  echo "    Then create a Kueue CR with BatchJob framework enabled."
  echo ""
  exit 1
fi
log "Kueue CRDs present"

log "Checking Slurm controller..."
CTRL=$(oc get pods -n "$SLURM_NS" -l app.kubernetes.io/name=slurmctld \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CTRL" ]; then
  echo "  slurmctld pod not found in namespace '$SLURM_NS'"
  echo "  Run ./scripts/deploy.sh first."
  exit 1
fi
log "slurmctld: $CTRL"

log "Checking Slurm Bridge..."
BRIDGE_PODS=$(oc get pods -n "$OPERATOR_NS" -l app.kubernetes.io/name=slurm-bridge \
  --no-headers 2>/dev/null | wc -l || echo 0)
if [ "$BRIDGE_PODS" -eq 0 ]; then
  warn "Slurm Bridge pods not found in '$OPERATOR_NS' — jobs may not route to Slurm"
fi
log "Bridge pods: $BRIDGE_PODS"

# ---------------------------------------------------------------------------
# Set up Kueue queues
# ---------------------------------------------------------------------------
section "Setting up Kueue queues"

log "Applying ClusterQueue + ResourceFlavor (200m CPU quota)..."
oc apply -f "${REPO_ROOT}/configs/kueue.yaml"

log "Creating demo namespace: $DEMO_NS"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $DEMO_NS
  labels:
    managed-by-slurm: "true"
    kueue.openshift.io/managed: "true"
    kueue.io/managed: "true"
EOF

log "Creating LocalQueue '$QUEUE_NAME' in $DEMO_NS..."
oc apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: $QUEUE_NAME
  namespace: $DEMO_NS
spec:
  clusterQueue: slurm-cluster-queue
EOF

info "Queue setup complete. Quota: 200m CPU total — one 200m job at a time."

# ---------------------------------------------------------------------------
# Submit Job 1 (takes the full quota, runs for 45s)
# ---------------------------------------------------------------------------
section "Submitting Job 1 (fills quota for ~45 seconds)"

oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kueue-demo-job-1
  namespace: $DEMO_NS
  labels:
    kueue.x-k8s.io/queue-name: $QUEUE_NAME
  annotations:
    slurmjob.slinky.slurm.net/account: slurm
    slurmjob.slinky.slurm.net/partition: all
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      annotations:
        slurmjob.slinky.slurm.net/account: slurm
        slurmjob.slinky.slurm.net/partition: all
    spec:
      containers:
      - name: worker
        image: quay.io/prometheus/busybox
        command: [sh, -c, "echo '[Job 1] started on \$(hostname)' && sleep 45 && echo '[Job 1] complete'"]
        resources:
          requests:
            cpu: 200m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 128Mi
      restartPolicy: Never
EOF

log "Job 1 submitted. Waiting 3s for Kueue to admit it..."
sleep 3

# ---------------------------------------------------------------------------
# Submit Job 2 (should be held by Kueue — quota full)
# ---------------------------------------------------------------------------
section "Submitting Job 2 (should be held by Kueue)"

oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kueue-demo-job-2
  namespace: $DEMO_NS
  labels:
    kueue.x-k8s.io/queue-name: $QUEUE_NAME
  annotations:
    slurmjob.slinky.slurm.net/account: slurm
    slurmjob.slinky.slurm.net/partition: all
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      annotations:
        slurmjob.slinky.slurm.net/account: slurm
        slurmjob.slinky.slurm.net/partition: all
    spec:
      containers:
      - name: worker
        image: quay.io/prometheus/busybox
        command: [sh, -c, "echo '[Job 2] started on \$(hostname)' && echo '[Job 2] complete'"]
        resources:
          requests:
            cpu: 200m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 128Mi
      restartPolicy: Never
EOF

log "Job 2 submitted."

# ---------------------------------------------------------------------------
# Monitor: show Kueue holding Job 2, Job 1 running via Slurm
# ---------------------------------------------------------------------------
section "Monitoring — Kueue queue + Slurm queue"

info "Watching for up to 90 seconds. Job 2 should be HELD until Job 1 finishes."
echo ""

DEADLINE=$(($(date +%s) + 90))
JOB2_ADMITTED=false

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  echo -e "${CYAN}── Kueue Workloads ──────────────────────────${NC}"
  oc get workloads -n "$DEMO_NS" \
    -o custom-columns='NAME:.metadata.name,ADMITTED:.status.conditions[?(@.type=="Admitted")].status,QUEUE:.spec.queueName' \
    2>/dev/null || true

  echo ""
  echo -e "${CYAN}── Slurm Queue (squeue) ─────────────────────${NC}"
  oc exec -n "$SLURM_NS" "$CTRL" -c slurmctld -- squeue 2>/dev/null || true

  echo ""

  # Check if Job 2 workload is now admitted
  J2_STATUS=$(oc get workloads -n "$DEMO_NS" \
    -o jsonpath='{.items[?(@.metadata.labels.kueue\.x-k8s\.io/job-uid)].status.conditions[?(@.type=="Admitted")].status}' \
    2>/dev/null || echo "")

  # Check if both jobs are done
  J1_DONE=$(oc get job kueue-demo-job-1 -n "$DEMO_NS" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
  J2_DONE=$(oc get job kueue-demo-job-2 -n "$DEMO_NS" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")

  if [ "$JOB2_ADMITTED" = false ]; then
    # Check workload admission via conditions
    WL2_ADMITTED=$(oc get workloads -n "$DEMO_NS" \
      --selector "kueue.x-k8s.io/job-uid" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Admitted")]}{.status}{end}{"\n"}{end}' \
      2>/dev/null | grep "job-2" | grep -c "True" || echo "0")
    if [ "$WL2_ADMITTED" -gt 0 ]; then
      log "Job 2 admitted by Kueue — Bridge will now intercept its pod"
      JOB2_ADMITTED=true
    fi
  fi

  if [ "${J1_DONE:-0}" = "1" ] && [ "${J2_DONE:-0}" = "1" ]; then
    echo ""
    log "Both jobs complete."
    break
  fi

  sleep 8
done

# ---------------------------------------------------------------------------
# Final status
# ---------------------------------------------------------------------------
section "Final status"

echo -e "${CYAN}── Kueue Workloads ──────────────────────────${NC}"
oc get workloads -n "$DEMO_NS" 2>/dev/null || true

echo ""
echo -e "${CYAN}── K8s Jobs ─────────────────────────────────${NC}"
oc get jobs -n "$DEMO_NS" 2>/dev/null || true

echo ""
echo -e "${CYAN}── Slurm job history (sacct) ─────────────────${NC}"
oc exec -n "$SLURM_NS" "$CTRL" -c slurmctld -- \
  sacct -X --format=JobID,JobName,State,Start,End,Elapsed 2>/dev/null || true

echo ""
section "Demo complete"
log "What happened:"
echo "  1. Job 1 was admitted by Kueue (200m CPU quota — fully consumed)"
echo "  2. Job 2 was submitted and HELD by Kueue (quota full)"
echo "  3. Slurm Bridge intercepted Job 1's pod and routed it to slurmctld"
echo "  4. Slurm ran Job 1; autoscaler scaled up a worker if needed"
echo "  5. When Job 1 finished, Kueue admitted Job 2"
echo "  6. Bridge intercepted Job 2's pod → Slurm ran it"
echo ""
log "To clean up: $0 --cleanup"
