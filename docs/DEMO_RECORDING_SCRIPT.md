# Demo Recording Script

Step-by-step runbook for producing the end-to-end demo video (deploy → trigger
job → observe changes on OpenShift → results). Designed to be recorded with a
screen capture tool while narrating.

---

## Setup (do before recording)

1. **Clean slate:** make sure the cluster has no leftover `slurm` or
   `text-classifier-*` namespaces from a prior run.
2. **Terminal layout:** one terminal pane for commands, optionally a second
   showing the OpenShift web console (Workloads → Pods view) for visual context.
3. **Pre-built image:** the training image should already be built and pushed
   (see `docs/DEMO.md`). This avoids a 2-minute build step in the recording.
4. **Set the image variable** so commands are copy-pasteable:
   ```bash
   export IMAGE=image-registry.openshift-image-registry.svc:5000/text-classifier-build/text-classifier-trainer:latest
   ```

---

## Part 1: Deploy Slurm + Bridge (~3 min)

**Narration:** *"We're deploying a full Slurm cluster inside OpenShift —
controller, REST API, and Slurm Bridge — using a single script."*

```bash
./scripts/deploy.sh --skip-operator
```

**Show:** pods coming up in the `slurm` namespace.

```bash
oc get pods -n slurm
```

**Narration:** *"Six pods: the Slurm controller, REST API, and three Bridge
components (admission, scheduler, controllers). The Slinky operator was
already installed. Everything's ready."*

---

## Part 2: Submit training job via Bridge (~2 min)

**Narration:** *"Now the key part — we're submitting a PyTorch training job
as a standard Kubernetes Job. The namespace is labeled `managed-by-slurm`,
so Bridge will intercept it and route it through Slurm. Nothing in the job
spec mentions Slurm."*

```bash
./demos/text-classifier-demo.sh --image $IMAGE
```

While the script runs, **switch to the OpenShift console** and show:
- The `text-classifier-demo` namespace appearing
- The training pod going from Pending → Running
- (Optional) the pod's node assignment

**Also show** it's actually in Slurm's queue:

```bash
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- squeue
```

**Narration:** *"There it is in Slurm's job queue — the Bridge translated
our Kubernetes Job into an sbatch job, and Slurm scheduled it onto one of
our labeled worker nodes."*

---

## Part 3: Training progress (time-lapse or skip) (~1 min shown)

**Narration:** *"The training takes about 35 minutes on CPU. Here's what the
output looks like as it runs..."*

Either:
- **Time-lapse** the log tail (speed up the recording 20x for this segment), or
- **Cut** to a pre-recorded segment showing the key log lines appearing:
  ```
  baseline (pre-training) accuracy=0.2345
  epoch 1/3 train_loss=0.3831 eval_accuracy=0.9035
  epoch 2/3 train_loss=0.1955 eval_accuracy=0.9110
  epoch 3/3 train_loss=0.1106 eval_accuracy=0.9030
  ```

**Narration:** *"Started at 23% accuracy — basically random for 4 classes —
and ended at 90%. The model actually learned."*

---

## Part 4: Show tangible results (~2 min)

**Narration:** *"Now let's use the fine-tuned model to classify real headlines
— ones it's never seen before."*

```bash
python3 training/predict.py \
  --checkpoint-dir results/text-classifier-demo/checkpoint \
  --text \
  "Apple unveils new chip for the iPhone, promising faster AI performance" \
  "Lakers win in overtime thriller to clinch playoff spot" \
  "Federal Reserve raises interest rates amid inflation concerns" \
  "Rebel forces seize control of capital after weeks of fighting"
```

**Expected output:**
```
"Apple unveils new chip for the iPhone..."  → Sci/Tech (99.3%)
"Lakers win in overtime thriller..."         → Sports (99.8%)
"Federal Reserve raises interest rates..."   → Business (99.6%)
"Rebel forces seize control of capital..."   → World (99.8%)
```

**Narration:** *"Four completely new headlines, all classified correctly at
99%+ confidence. The model generalizes, it doesn't just memorize the training
data."*

---

## Part 5: Cleanup (~30s)

```bash
./demos/text-classifier-demo.sh --cleanup
./scripts/cleanup.sh
```

**Narration:** *"Clean teardown — namespace deleted, Slurm cluster removed,
cluster back to original state."*

---

## Key talking points to weave in

- **Why Bridge matters:** the training Job is a plain Kubernetes object. Any
  K8s-native tool (OpenShift AI, Argo, a notebook) can submit these without
  knowing Slurm exists. Bridge is the translation layer.
- **Why Slurm matters:** Slurm provides HPC-grade scheduling, job accounting,
  fair-share queuing, and multi-node coordination — things Kubernetes' default
  scheduler wasn't designed for.
- **What this proves:** the two systems compose cleanly. You get Kubernetes'
  ecosystem for orchestration and Slurm's strengths for scheduling, without
  either one needing to know about the other.

---

## Timing estimate

| Segment | Real time | Shown in video |
|---------|-----------|----------------|
| Deploy | ~3 min | ~3 min |
| Submit + show routing | ~2 min | ~2 min |
| Training (time-lapse) | ~36 min | ~1 min |
| Results (predict.py) | ~1 min | ~2 min |
| Cleanup | ~1 min | ~30s |
| **Total** | ~43 min | **~8.5 min** |
