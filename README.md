# Slurm Bridge on OCP

Proof of concept: deploy Slurm with [Slurm Bridge](https://slinky.schedmd.com/) on Red Hat OpenShift and run a practical PyTorch workload through it. Extends [slurm-on-ocp](https://github.com/RHEcosystemAppEng/slurm-on-ocp) with Kubernetes-native job submission via Bridge.

## What's different from slurm-on-ocp

| | slurm-on-ocp | slurm-bridge-on-ocp |
|---|---|---|
| Deployment | Raw YAML CRs | Helm chart (includes REST API) |
| Slurm REST API | Not deployed | Deployed (required by Bridge) |
| Slurm Bridge | Not included | Included |
| Job submission | `oc exec ... sbatch` | Kubernetes Pods/Jobs via Bridge |

## Quick Start

```bash
# Prerequisites: oc logged in, helm installed, cert-manager on cluster

# Deploy operator + Slurm cluster + Bridge
./scripts/deploy.sh

# If operator already installed via OperatorHub
./scripts/deploy.sh --skip-operator

# Verify components are up
oc get pods -n slurm

# Smoke test: submit a pod through Bridge
oc project default
oc label namespace default managed-by-slurm=true --overwrite
oc delete pod bridge-test -n default --ignore-not-found
oc run bridge-test -n default --image=quay.io/prometheus/busybox --restart=Never \
  --overrides='{"metadata":{"annotations":{"slurmjob.slinky.slurm.net/account":"slurm","slurmjob.slinky.slurm.net/partition":"all"}}}' \
  -- sh -c "hostname && date"

# Wait for Bridge to schedule through Slurm, then check logs
oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/bridge-test -n default --timeout=120s
oc logs bridge-test -n default
```

## PyTorch Demo

The main workload is a DistilBERT fine-tuning job on AG News, submitted as a plain Kubernetes Job routed through Bridge:

```bash
# Build the training image (see docs/DEMO.md for in-cluster or external options)
./demos/text-classifier-demo.sh --image <your-training-image>

# With GPU(s) — requires NVIDIA GPU Operator on the cluster
./demos/text-classifier-demo.sh --image <your-training-image> --gpu 1
```

Baseline accuracy starts at chance level (~25%, 4 classes) and reaches ~90% after training. The training image auto-detects CUDA and falls back to CPU when no GPUs are available. See [`docs/DEMO.md`](docs/DEMO.md) for the full walkthrough, build instructions, and known gotchas.

## Repository Structure

```
slurm-bridge-on-ocp/
├── configs/
│   ├── slurm-values.yaml          # Helm values for Slurm cluster
│   ├── slurm-bridge-values.yaml   # Helm values for Slurm Bridge
│   └── token.yaml                 # JWT Token CR (Bridge → slurmrestd auth)
├── scripts/
│   ├── deploy.sh                  # Master deploy (operator → cluster → bridge)
│   ├── deploy-operator.sh         # Step 1: Slinky operator CRDs + operator
│   ├── deploy-slurm.sh            # Step 2: Slurm cluster via Helm
│   ├── deploy-bridge.sh           # Step 3: Bridge + token + node labels + RBAC
│   └── cleanup.sh                 # Tear down (cluster + bridge; optional: operator)
├── training/
│   ├── train.py                   # DistilBERT fine-tuning (torchrun/DDP-ready, GPU/CPU)
│   ├── predict.py                 # Run the fine-tuned checkpoint on headlines
│   ├── Dockerfile                 # GPU training image (CUDA + PyTorch, auto-detects GPU)
│   ├── Dockerfile.cpu             # CPU-only training image (smaller, ~2 GB)
│   ├── requirements.txt           # torch/transformers/pandas, pinned
│   ├── data/                      # Vendored AG News subset (8k train / 2k test, ~2 MB)
│   └── data-full/                 # Full AG News dataset (120k train / 7.6k test, ~30 MB)
├── demos/
│   └── text-classifier-demo.sh    # End-to-end PyTorch demo via Bridge
└── docs/
    ├── ARCHITECTURE.md            # System design and job flow
    ├── DEPLOYMENT_GUIDE.md        # Step-by-step deployment reference
    ├── DEMO.md                    # Text classifier demo walkthrough
    └── DEMO_RECORDING_SCRIPT.md   # Runbook for recording the demo video
```

## How It Works

**Slinky** runs Slurm inside OpenShift — the operator reconciles Controller and NodeSet CRs into slurmctld/slurmd pods. The Helm chart also deploys `slurmrestd` (Slurm REST API), which Bridge uses for job submission.

**Slurm Bridge** intercepts pods created in namespaces labeled `managed-by-slurm: "true"` and schedules them via Slurm instead of the default Kubernetes scheduler. Bridge jobs run on OCP worker nodes labeled as external nodes during deployment.

## Cleanup

```bash
# Remove cluster + bridge (keep operator)
./scripts/cleanup.sh

# Full uninstall
./scripts/cleanup.sh --remove-operator
```

## References

- [Slinky Project](https://slinky.schedmd.com/)
- [slurm-on-ocp](https://github.com/RHEcosystemAppEng/slurm-on-ocp) — base project
