#!/bin/bash
set -euo pipefail

###############################################################################
# Text Classifier Fine-Tuning Demo — Slurm Bridge
#
# Fine-tunes distilbert-base-uncased on a small AG News subset (4-class news
# topic classification: World/Sports/Business/Sci-Tech) as a Kubernetes Job
# submitted through Slurm Bridge — NOT via `oc exec ... sbatch`. That's the
# whole point of this demo: proving out the Kubernetes-native submission path
# slurm-bridge-on-ocp adds on top of plain slurm-on-ocp.
#
# The classification head is randomly initialized, so accuracy starts near
# chance level (~25%, 4 classes) before training and reaches ~90% after
# fine-tuning on the vendored subset (training/data/).
#
# Prerequisites:
#   - Slurm Bridge deployed (./scripts/deploy.sh)
#   - Training image built from training/Dockerfile and pushed to a registry
#     the cluster can pull from (see docs/DEMO.md or the Dockerfile header
#     for both an in-cluster and an external build option) — pass it with
#     --image
#
# Usage:
#   ./demos/text-classifier-demo.sh --image quay.io/you/slurm-bridge-text-classifier:latest
#   ./demos/text-classifier-demo.sh --image <image> --epochs 5 --nproc 2
#   ./demos/text-classifier-demo.sh --image <image> --gpu 1          # single GPU
#   ./demos/text-classifier-demo.sh --image <image> --gpu 2          # multi-GPU (nproc auto-matches)
#   ./demos/text-classifier-demo.sh --image <image> --dataset full   # full AG News (120k rows)
#   ./demos/text-classifier-demo.sh --cleanup
###############################################################################

SLURM_NS="${SLURM_NS:-slurm}"
DEMO_NS="${DEMO_NS:-text-classifier-demo}"
JOB_NAME="text-classifier-training"
IMAGE="${IMAGE:-}"
DATASET="${DATASET:-default}"
EPOCHS="${EPOCHS:-3}"
NPROC="${NPROC:-2}"
# Two DDP processes each hold a full DistilBERT + AdamW optimizer state (~1GB
# each) plus activation memory for backward passes — 3Gi/6Gi OOMKilled
# (exit 137) partway through epoch 1 in live testing. 6Gi/12Gi has headroom.
GPU_COUNT="${GPU_COUNT:-0}"
CPU_REQUEST="${CPU_REQUEST:-2}"
CPU_LIMIT="${CPU_LIMIT:-4}"
MEM_REQUEST="${MEM_REQUEST:-6Gi}"
MEM_LIMIT="${MEM_LIMIT:-12Gi}"
# torchrun defaults OMP_NUM_THREADS=1/process when nproc_per_node>1 (to avoid
# oversubscription) — overly conservative here given the CPU limit above;
# explicitly widening it noticeably speeds up training.
OMP_THREADS="${OMP_THREADS:-2}"
# Live CPU training (3 epochs, 8k rows, 2 processes) took ~65 minutes in
# testing — 1800s was not enough.
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-5400}"
# How long the container stays alive (via a trailing `sleep`) after writing
# results, so there's a window to `oc cp` them out. `oc cp`/`exec` fail
# outright against a pod once its container has exited ("cannot exec into a
# container in a completed pod") — there is no way to retrieve files after
# the fact, so this grace period is required, not just a nice-to-have.
RESULTS_GRACE_SECONDS="${RESULTS_GRACE_SECONDS:-180}"
CLEANUP=false
NPROC_EXPLICIT=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="${REPO_ROOT}/results/text-classifier-demo"

# Each run gets its own timestamped subdirectory with a device tag so
# successive runs (CPU vs GPU, different hyperparams) don't clobber each
# other and can be compared side-by-side.
_run_timestamp="$(date +%Y-%m-%d_%H%M%S)"
if [ "$GPU_COUNT" -gt 0 ] 2>/dev/null; then
  _run_tag="gpu-${GPU_COUNT}"
else
  _run_tag="cpu"
fi
RESULTS_DIR="${RESULTS_BASE}/${_run_timestamp}_${_run_tag}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --slurm-ns)  SLURM_NS="$2"; shift 2 ;;
    --namespace) DEMO_NS="$2"; shift 2 ;;
    --image)     IMAGE="$2"; shift 2 ;;
    --dataset)   DATASET="$2"; shift 2 ;;
    --epochs)    EPOCHS="$2"; shift 2 ;;
    --nproc)     NPROC="$2"; NPROC_EXPLICIT=true; shift 2 ;;
    --gpu)       GPU_COUNT="$2"; shift 2 ;;
    --timeout)   TIMEOUT_SECONDS="$2"; shift 2 ;;
    --cleanup)   CLEANUP=true; shift ;;
    --help|-h)
      sed -n '3,22p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
info()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $*"; }
error()   { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $*"; }
section() { echo ""; echo -e "${BLUE}━━━ $* ━━━${NC}"; echo ""; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  section "Cleanup"
  log "Removing demo namespace..."
  oc delete namespace "$DEMO_NS" --ignore-not-found
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

if [ -z "$IMAGE" ]; then
  error "No training image specified."
  echo ""
  echo "  Option A — build in-cluster (no external registry needed; put the build"
  echo "  in its OWN namespace, NOT one labeled managed-by-slurm=true — Bridge"
  echo "  intercepts every pod in such a namespace, including build pods, and will"
  echo "  hang retrying to schedule it via Slurm):"
  echo "    oc new-project text-classifier-build"
  echo "    oc new-build --name=text-classifier-trainer --binary --strategy=docker"
  echo "    oc start-build text-classifier-trainer --from-dir=training/ --follow"
  echo "    oc policy add-role-to-group system:image-puller system:serviceaccounts:$DEMO_NS \\"
  echo "      -n text-classifier-build"
  echo "    ./demos/text-classifier-demo.sh \\"
  echo "      --image image-registry.openshift-image-registry.svc:5000/text-classifier-build/text-classifier-trainer:latest"
  echo ""
  echo "  Option B — build/push externally:"
  echo "    podman build -t <registry>/<repo>/slurm-bridge-text-classifier:latest \\"
  echo "      -f training/Dockerfile training/"
  echo "    podman push <registry>/<repo>/slurm-bridge-text-classifier:latest"
  echo "    ./demos/text-classifier-demo.sh --image <registry>/<repo>/slurm-bridge-text-classifier:latest"
  echo ""
  exit 1
fi
case "$DATASET" in
  default)  DATA_DIR="/app/data" ;;
  full)     DATA_DIR="/app/data-full" ;;
  *)        error "Unknown dataset: $DATASET (use 'default' or 'full')"; exit 1 ;;
esac
log "Image: $IMAGE"
log "Dataset: $DATASET ($DATA_DIR)"

GPU_TOLERATIONS=""
if [ "$GPU_COUNT" -gt 0 ] 2>/dev/null; then
  if [ "$NPROC_EXPLICIT" = false ]; then
    NPROC="$GPU_COUNT"
  fi
  log "GPU mode: ${GPU_COUNT} GPU(s), nproc_per_node=${NPROC}"

  # Auto-discover taints on GPU nodes so the Job can tolerate them.
  # Many clusters taint GPU nodes (e.g. g5-gpu=true:NoSchedule) to keep
  # non-GPU workloads off them — without matching tolerations the pod
  # stays Pending with "untolerated taint(s)".
  _seen_taints=""
  for _taint in $(oc get nodes -o jsonpath='{range .items[?(@.status.capacity.nvidia\.com/gpu)]}{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}{end}' 2>/dev/null | grep -v slinky | sort -u); do
    _key=$(echo "$_taint" | cut -d= -f1)
    _val=$(echo "$_taint" | cut -d= -f2 | cut -d: -f1)
    _eff=$(echo "$_taint" | cut -d: -f2)
    if echo "$_seen_taints" | grep -qF "$_key"; then continue; fi
    _seen_taints="${_seen_taints} ${_key}"
    GPU_TOLERATIONS="${GPU_TOLERATIONS}
        - key: \"${_key}\"
          operator: \"Equal\"
          value: \"${_val}\"
          effect: \"${_eff}\""
    log "Adding toleration: ${_key}=${_val}:${_eff}"
  done
fi

log "Checking Slurm controller..."
CTRL=$(oc get pods -n "$SLURM_NS" -l app.kubernetes.io/name=slurmctld \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CTRL" ]; then
  error "slurmctld pod not found in namespace '$SLURM_NS'"
  error "Run ./scripts/deploy.sh first."
  exit 1
fi
log "slurmctld: $CTRL"

log "Checking Slurm Bridge..."
BRIDGE_PODS=$(oc get pods -n "$SLURM_NS" -l app.kubernetes.io/name=slurm-bridge \
  --no-headers 2>/dev/null | wc -l || echo 0)
if [ "$BRIDGE_PODS" -eq 0 ]; then
  warn "Slurm Bridge pods not found in '$SLURM_NS' — job may not route to Slurm"
else
  log "Bridge pods: $BRIDGE_PODS"
fi

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
section "Setting up namespace"

log "Creating namespace: $DEMO_NS (labeled managed-by-slurm=true)"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $DEMO_NS
  labels:
    managed-by-slurm: "true"
EOF

# ---------------------------------------------------------------------------
# Submit training job
# ---------------------------------------------------------------------------
section "Submitting training job"

info "distilbert-base-uncased on AG News (4-class) — baseline ~25% (chance), targeting ~90%"
log "epochs=$EPOCHS nproc_per_node=$NPROC cpu=${CPU_REQUEST}-${CPU_LIMIT} mem=${MEM_REQUEST}-${MEM_LIMIT}"

oc delete job "$JOB_NAME" -n "$DEMO_NS" --ignore-not-found >/dev/null 2>&1 || true

oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $DEMO_NS
  annotations:
    slurmjob.slinky.slurm.net/account: slurm
    slurmjob.slinky.slurm.net/partition: all
spec:
  backoffLimit: 0
  template:
    metadata:
      annotations:
        slurmjob.slinky.slurm.net/account: slurm
        slurmjob.slinky.slurm.net/partition: all
    spec:
      restartPolicy: Never${GPU_TOLERATIONS:+
      tolerations:${GPU_TOLERATIONS}}
      containers:
        - name: trainer
          image: $IMAGE
          # Trailing sleep keeps the container (and pod phase) alive after
          # training finishes so the demo script has a window to \`oc cp\`
          # results out — exec/cp are refused entirely once a container has
          # exited, so this isn't optional.
          command:
            - /bin/sh
            - -c
            - |
              torchrun --nnodes=1 --nproc_per_node=$NPROC /app/train.py --epochs=$EPOCHS --data-dir=$DATA_DIR --output-dir=/results
              status=\$?
              echo "[entrypoint] training exited \$status, keeping pod alive ${RESULTS_GRACE_SECONDS}s for results retrieval..."
              sleep $RESULTS_GRACE_SECONDS
              exit \$status
          env:
            - name: OMP_NUM_THREADS
              value: "$OMP_THREADS"
          resources:
            requests:
              cpu: "$CPU_REQUEST"
              memory: "$MEM_REQUEST"$([ "$GPU_COUNT" -gt 0 ] 2>/dev/null && printf '\n              nvidia.com/gpu: "%s"' "$GPU_COUNT")
            limits:
              cpu: "$CPU_LIMIT"
              memory: "$MEM_LIMIT"$([ "$GPU_COUNT" -gt 0 ] 2>/dev/null && printf '\n              nvidia.com/gpu: "%s"' "$GPU_COUNT")
          volumeMounts:
            - name: results
              mountPath: /results
      volumes:
        - name: results
          emptyDir: {}
EOF

log "Job submitted: $JOB_NAME"

# ---------------------------------------------------------------------------
# Monitor
# ---------------------------------------------------------------------------
section "Monitoring training"

info "Waiting for pod to be scheduled by Bridge (this can take a minute)..."
DEADLINE=$(($(date +%s) + TIMEOUT_SECONDS))
POD=""

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  POD=$(oc get pods -n "$DEMO_NS" -l job-name="$JOB_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$POD" ]; then
    break
  fi
  sleep 5
done

if [ -z "$POD" ]; then
  error "Pod for job '$JOB_NAME' never appeared within ${TIMEOUT_SECONDS}s"
  exit 1
fi
log "Pod: $POD"

info "Tailing logs and polling every 10s (timeout: ${TIMEOUT_SECONDS}s)..."
echo ""

# NOTE: completion is detected by checking for /results/metrics.json inside
# the (still-Running, thanks to the trailing sleep) pod — NOT by waiting for
# the Job's .status.succeeded field. That field only flips once the
# container fully exits, i.e. after the grace-period sleep — by which point
# the pod would already be gone and unreachable for retrieval. Checking the
# Job status here would be too late.
STATUS=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  echo -e "${CYAN}── training log (tail) ───────────────────────${NC}"
  oc logs -n "$DEMO_NS" "$POD" --tail=15 2>/dev/null || true
  echo ""

  FAILED=$(oc get job "$JOB_NAME" -n "$DEMO_NS" -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
  if [ "${FAILED:-0}" -ge "1" ] 2>/dev/null; then
    STATUS="failed"
    break
  fi

  if oc exec -n "$DEMO_NS" "$POD" -- test -f /results/metrics.json 2>/dev/null; then
    STATUS="succeeded"
    break
  fi

  sleep 10
done

if [ -z "$STATUS" ]; then
  error "Job did not complete within ${TIMEOUT_SECONDS}s — check manually:"
  error "  oc logs -n $DEMO_NS $POD"
  exit 1
fi

if [ "$STATUS" = "failed" ]; then
  error "Training job failed. Full logs:"
  oc logs -n "$DEMO_NS" "$POD" || true
  exit 1
fi

log "Training succeeded — results ready, pod staying alive ~${RESULTS_GRACE_SECONDS}s for retrieval"

# ---------------------------------------------------------------------------
# Retrieve results
# ---------------------------------------------------------------------------
section "Retrieving results"

mkdir -p "$RESULTS_DIR"
if oc cp "$DEMO_NS/$POD:/results/metrics.json" "$RESULTS_DIR/metrics.json" 2>/dev/null; then
  log "Saved metrics to $RESULTS_DIR/metrics.json"
  echo ""
  python3 -c "
import json
m = json.load(open('$RESULTS_DIR/metrics.json'))
print(f\"  Model:             {m['model_name']}\")
print(f\"  Train / test rows: {m['train_rows']} / {m['test_rows']}\")
print(f\"  Baseline accuracy: {m['baseline_accuracy']:.2%} (chance level, 4 classes)\")
for e in m['epochs']:
    print(f\"  Epoch {e['epoch']}: train_loss={e['train_loss']:.4f} eval_accuracy={e['eval_accuracy']:.2%}\")
print(f\"  Final accuracy:    {m['final_accuracy']:.2%}\")
" 2>/dev/null || warn "Could not pretty-print metrics.json — see the file directly"
else
  warn "Could not retrieve metrics.json (pod may have already been cleaned up)"
fi

log "Pulling fine-tuned checkpoint (for training/predict.py)..."
if oc cp "$DEMO_NS/$POD:/results/checkpoint" "$RESULTS_DIR/checkpoint" 2>/dev/null; then
  log "Saved checkpoint to $RESULTS_DIR/checkpoint"
else
  warn "Could not retrieve checkpoint directory"
fi

ln -sfn "$RESULTS_DIR" "$RESULTS_BASE/latest"
log "Symlinked latest → $(basename "$RESULTS_DIR")"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
section "Demo complete"
log "What happened:"
echo "  1. Namespace '$DEMO_NS' was labeled managed-by-slurm=true"
echo "  2. A training Job was submitted as a plain Kubernetes Job (no sbatch)"
echo "  3. Slurm Bridge intercepted the pod and routed it to slurmctld"
echo "  4. Slurm ran it on the external node pool; torchrun fine-tuned"
echo "     distilbert-base-uncased on AG News inside the pod"
echo "  5. Accuracy moved from chance level (~25%) to ~90%"
echo ""
log "Results saved to: $RESULTS_DIR"
log "Latest symlink:   $RESULTS_BASE/latest"
log "All runs:         ls $RESULTS_BASE/"
log "Try the fine-tuned model on real headlines:"
log "  pip install torch transformers pandas  # if not already installed locally"
log "  python3 training/predict.py --checkpoint-dir $RESULTS_DIR/checkpoint --interactive"
log "To clean up: $0 --cleanup"
