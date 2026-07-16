# Demo — Text Classifier Fine-Tuning via Slurm Bridge

## Use case

Fine-tune a pretrained Hugging Face model (`distilbert-base-uncased`) into a
4-class news topic classifier (World / Sports / Business / Sci-Tech) using
the vendored [AG News](https://huggingface.co/datasets/fancyzhx/ag_news)
subset in `training/data/`. The classification head is randomly initialized,
so accuracy starts at chance level (~25%, 4 classes) and reaches ~90% after
a few epochs of fine-tuning (confirmed via live testing — see "Live-tested
results" below).

This is a small, fast, realistic stand-in for an HPC-style training
workload — the kind of job Slurm is built for — run entirely inside
OpenShift.

## Why this has to go through Bridge, not `oc exec ... sbatch`

The rest of this repo (and plain `slurm-on-ocp`) can already run Slurm jobs
via `oc exec -n slurm <controller> -c slurmctld -- sbatch ...`. That works,
but it means anything that wants to use Slurm has to know it's talking to
Slurm — shelling into a specific pod, in a specific namespace, running a
Slurm-specific CLI.

Slurm Bridge removes that requirement. The training job here is submitted as
an ordinary Kubernetes `batch/v1` Job — the same object any Kubernetes-native
tool (a notebook, a pipeline, a CI system, OpenShift AI) already knows how to
create — in a namespace labeled `managed-by-slurm: "true"`. Bridge's
admission controller intercepts the Pod, translates it into an `sbatch` job
via the Slurm REST API, and Slurm schedules and runs it exactly as it would
any other job. Nothing in the training workload's definition needs to know
Slurm exists.

That's the actual value proposition this repo demonstrates: **Slurm's
scheduling and resource management, exposed through a fully Kubernetes-native
submission path.**

## Running it

```bash
# 1. Build the training image — in-cluster (no external registry needed):
#
#    IMPORTANT: put the build in its OWN namespace, NOT one labeled
#    managed-by-slurm=true. Bridge's admission controller intercepts every
#    pod created in such a namespace, including OpenShift's own build pods —
#    it will repeatedly (and silently, from the pod's perspective — check
#    the Bridge scheduler's logs to see it) try and fail to schedule the
#    build pod via Slurm, since build pods need a privileged/hostPath
#    security context Slurm has no way to satisfy. The pod just sits in
#    Pending forever with no scheduling events at all, which is a confusing
#    thing to debug blind — confirmed by hitting it in live testing.
oc new-project text-classifier-build
oc new-build --name=text-classifier-trainer --binary --strategy=docker
oc start-build text-classifier-trainer --from-dir=training/ --follow
oc policy add-role-to-group system:image-puller \
  system:serviceaccounts:text-classifier-demo -n text-classifier-build

# 2. Run the demo (CPU)
./demos/text-classifier-demo.sh \
  --image image-registry.openshift-image-registry.svc:5000/text-classifier-build/text-classifier-trainer:latest

# 2b. Or with GPU(s) — nproc_per_node auto-matches GPU count
./demos/text-classifier-demo.sh \
  --image image-registry.openshift-image-registry.svc:5000/text-classifier-build/text-classifier-trainer:latest \
  --gpu 1

# (Alternative to step 1: build/push externally instead —
#  podman build -t <registry>/<repo>/slurm-bridge-text-classifier:latest -f training/Dockerfile training/
#  podman push <registry>/<repo>/slurm-bridge-text-classifier:latest
#  For CPU-only: use -f training/Dockerfile.cpu instead)

# 3. Clean up
./demos/text-classifier-demo.sh --cleanup
```

The script labels a namespace, submits the training Job, tails logs while it
runs, and pulls the final `metrics.json` (baseline vs. per-epoch vs. final
accuracy) plus the fine-tuned checkpoint into `results/text-classifier-demo/`.

## Monitoring a running job

The demo script tails logs automatically, but if you want to monitor from
a separate terminal:

```bash
# Pod status
oc get pods -n text-classifier-demo -o wide

# Live log stream
oc logs -n text-classifier-demo -l job-name=text-classifier-training -f

# Last few lines (non-blocking)
oc logs -n text-classifier-demo -l job-name=text-classifier-training --tail=20

# Check if Slurm is tracking it
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- squeue

# Pod events (useful if stuck in Pending/ContainerCreating)
oc describe pod -n text-classifier-demo -l job-name=text-classifier-training | tail -15
```

## Live-tested results

Run end-to-end on a real OpenShift cluster (3 epochs, 8,000 train / 2,000 test
rows, 2 DDP processes on CPU):

```
baseline (pre-training) accuracy = 23.45%   (chance level for 4 classes: 25%)
epoch 1/3  train_loss=0.3831  eval_accuracy=90.35%
epoch 2/3  train_loss=0.1956  eval_accuracy=90.80%
epoch 3/3  train_loss=0.1132  eval_accuracy=90.85%
```

Confirmed via `squeue` on `slurmctld` that the job was actually scheduled
and run by Slurm, not just by Kubernetes' default scheduler — i.e. Bridge
really did do its job. Total wall-clock time was **~36 minutes** on CPU with
the current defaults (`OMP_NUM_THREADS=2`, 4-CPU limit, 2 DDP processes);
see the "known gotchas" below for what that number is sensitive to.

## Known gotchas (found via live testing, not just code review)

- **Bridge intercepts *every* pod in a `managed-by-slurm=true` namespace**,
  not just the ones you intend to route through Slurm — see the build-image
  warning above. Keep build/infra namespaces separate from workload
  namespaces.
- **`oc cp`/`oc exec` cannot retrieve anything from a pod once its container
  has exited** ("cannot exec into a container in a completed pod") — there is
  no grace period on the Kubernetes side, it fails immediately once the
  container transitions out of Running. `demos/text-classifier-demo.sh`
  works around this by wrapping the training command with a trailing
  `sleep`, and by detecting completion via `oc exec ... test -f
  /results/metrics.json` (while the pod is still Running) instead of waiting
  for the Job's `.status.succeeded` field (which only flips *after* that
  sleep ends, by which point the pod is unreachable). If you're adapting this
  pattern elsewhere, don't assume you can grab results after a Job shows
  `Complete`.
- **CPU memory sizing**: two DDP processes each hold a full DistilBERT +
  AdamW optimizer (~1GB+ each) plus backward-pass activation memory. 3Gi
  request / 6Gi limit OOMKilled (exit 137) partway through epoch 1 in
  testing; 6Gi/12Gi has headroom.
- **`torchrun` defaults `OMP_NUM_THREADS=1` per process** when
  `nproc_per_node>1`, to avoid oversubscription — overly conservative given
  the CPU limits here, and roughly doubled training time until set
  explicitly (`OMP_NUM_THREADS=2` in the Job's env, given a 4-CPU limit and 2
  processes).
- **GPU pods stuck in Pending.** The deploy script labels only the first 3
  generic worker nodes as Bridge external nodes — GPU nodes won't be among
  them unless you label them explicitly. Without the label, Bridge has no
  eligible node to place a pod requesting `nvidia.com/gpu`, and it stays
  Pending with `Insufficient nvidia.com/gpu`. Fix:
  ```bash
  for node in $(oc get nodes -o jsonpath='{range .items[?(@.status.capacity.nvidia\.com/gpu)]}{.metadata.name}{"\n"}{end}'); do
    oc patch "node/$node" \
      -p '{"metadata":{"labels":{"scheduler.slinky.slurm.net/external-node":"true"},"annotations":{"scheduler.slinky.slurm.net/external-node-partitions":"all"}}}' \
      --type=merge
  done
  ```
- **Rebuild the image after switching Dockerfiles.** The default `Dockerfile`
  is GPU-capable (PyTorch CUDA base); `Dockerfile.cpu` is the smaller
  CPU-only variant. If you change which Dockerfile is used (or edit either
  one), you need to trigger a new build — the existing image in the registry
  still has the old layers:
  ```bash
  oc start-build text-classifier-trainer -n text-classifier-build --from-dir=training/ --follow
  ```
  `oc new-project` and `oc new-build` only need to run once; re-running
  `oc start-build` is enough to pick up Dockerfile/code changes.
- **`oc adm policy add-scc-to-user` is idempotent, so it should never
  legitimately fail** — if it does, that's a real problem (bad permissions,
  a transient API error), not "already granted". An earlier version of
  `deploy-slurm.sh` swallowed failures with that assumption, which once
  masked a real failure during testing and left pods stuck in confusing
  SCC-forbidden errors with no obvious cause. It now fails loudly instead.

### Trying the fine-tuned model on real headlines

`metrics.json` gives you accuracy numbers; `training/predict.py` gives you
the actual model in action — classify arbitrary text, sample from the test
set, or classify headlines interactively:

```bash
pip install torch transformers pandas  # if not already installed locally
python3 training/predict.py --checkpoint-dir results/text-classifier-demo/checkpoint \
  --text "Apple unveils new chip for the iPhone" "Lakers win in overtime thriller"

# or, live:
python3 training/predict.py --checkpoint-dir results/text-classifier-demo/checkpoint --interactive
```

It can also run inside the cluster with no extra install, since the training
image already has the checkpoint's dependencies baked in — but only *while
the training pod's container is still alive* (its trailing grace-period
`sleep`, by default ~180s after training finishes; `oc exec` stops working
entirely the moment it exits):

```bash
oc exec -n text-classifier-demo <pod> -- python3 /app/predict.py --checkpoint-dir /results/checkpoint --num-samples 5
```

For anything after that window, use the local copy pulled into
`results/text-classifier-demo/checkpoint/` instead.

## Design choices

- **GPU support (optional).** Pass `--gpu N` to the demo script to request
  N GPUs per pod. The training image (`Dockerfile`) uses a CUDA-capable
  PyTorch base and `train.py` auto-detects CUDA at runtime — if GPUs are
  present it uses them (with `nccl` DDP backend), otherwise it falls back to
  CPU (`gloo` backend). A smaller CPU-only image is available via
  `Dockerfile.cpu`. GPU nodes must have the NVIDIA GPU Operator (or NFD +
  device plugin) installed and be labeled as Bridge external nodes.
- **Single-node, multi-process.** The training job runs `torchrun` with
  multiple processes (`--nproc_per_node`) inside one Bridge-routed pod using
  PyTorch DDP. When using GPUs, nproc defaults to the GPU count (one process
  per device). `training/train.py` doesn't need to change to go multi-node
  later; only the launch command would.
- **Vendored dataset.** Two sizes are included, both baked into the image:
  - `training/data/` — 8k train / 2k test (~2 MB), the default, sized for
    fast CPU demos (~35 min).
  - `training/data-full/` — 120k train / 7.6k test (~30 MB), the full AG News
    dataset. Pass `--dataset full` to the demo script. Better for GPU runs or
    when you want higher accuracy.

  The training image also bakes in the pretrained model/tokenizer at build
  time — so the training job never depends on internet egress from inside the
  cluster.
- **Data license note.** AG News is provided by the academic community for
  research/non-commercial use — fine for this internal enablement demo (see
  `training/data/DATA_INFO.md`), but don't redistribute it externally without
  checking the original terms.
