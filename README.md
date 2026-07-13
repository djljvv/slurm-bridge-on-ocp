# Slurm Bridge on OCP

Deploys Slurm with Slurm Bridge on Red Hat OpenShift using the Slinky operator. Extends [slurm-on-ocp](https://github.com/RHEcosystemAppEng/slurm-on-ocp) with Bridge support and a queue-driven autoscaler design (see caveat below — scale-up currently doesn't trigger for direct `sbatch` under this chart's default config).

## What's different from slurm-on-ocp

| | slurm-on-ocp | slurm-bridge-on-ocp |
|---|---|---|
| Deployment | Raw YAML CRs | Helm chart (includes REST API) |
| Slurm REST API | Not deployed | Deployed (required by Bridge) |
| Slurm Bridge | Not included | Included |
| Autoscaler scale-up | Launcher script (client pre-scales before submit) | Reactive/queue-driven by design — currently non-functional, see below |
| Job submission | `oc exec ... sbatch` | `sbatch` direct or via Bridge API |

## Quick Start

```bash
# Prerequisites: oc logged in, helm installed, cert-manager on cluster

# Full deployment (operator + cluster + bridge + autoscaler)
./scripts/deploy.sh

# If operator already installed via OperatorHub
./scripts/deploy.sh --skip-operator

# Verify components are up (NOTE: ./scripts/test-slurm.sh's default "quick" mode
# currently fails on a fresh deploy — it submits an sbatch job before any worker
# has registered and hits the same rejection described below. Not yet fixed.)
oc get pods -n slurm

# Submit a job through Bridge (works from 0 replicas — Bridge schedules onto
# the underlying OCP worker nodes registered during deploy-bridge.sh)
oc label namespace default managed-by-slurm=true
oc run bridge-test --image=quay.io/prometheus/busybox --restart=Never \
  --overrides='{"metadata":{"annotations":{"slurmjob.slinky.slurm.net/account":"slurm","slurmjob.slinky.slurm.net/partition":"all"}}}' \
  -- sh -c "hostname && date"
```

> **Note:** direct `sbatch` (bypassing Bridge) does not actually trigger autoscaling under
> this chart's default config — Slurm rejects a job outright ("Requested node configuration
> is not available") instead of queuing it `PENDING` whenever it asks for more nodes than are
> currently registered, regardless of whether the NodeSet is at 0 or already has workers.
> Since the job never reaches `PENDING`, the autoscaler (which only reacts to `PENDING` jobs)
> never gets triggered. Bridge jobs work because they use a separate, statically-sized pool
> of "external nodes" — not the scaled NodeSet. See
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#autoscaler) for details and what it would
> take to make this actually work.

## Repository Structure

```
slurm-bridge-on-ocp/
├── configs/
│   ├── slurm-values.yaml          # Helm values for Slurm cluster
│   ├── slurm-bridge-values.yaml   # Helm values for Slurm Bridge
│   ├── slurm-autoscaler.yaml      # Autoscaler RBAC + Deployment
│   └── token.yaml                 # JWT Token CR (Bridge → slurmrestd auth)
├── scripts/
│   ├── deploy.sh                  # Master deploy (runs all steps in order)
│   ├── deploy-operator.sh         # Step 1: Slinky operator CRDs + operator
│   ├── deploy-slurm.sh            # Step 2: Slurm cluster via Helm
│   ├── deploy-bridge.sh           # Step 3: Bridge + token + node labels + RBAC
│   ├── deploy-autoscale.sh        # Step 4: Queue-driven autoscaler
│   ├── autoscaler-loop.sh         # Autoscaler loop (runs in-cluster)
│   ├── test-slurm.sh              # Cluster health checks
│   └── cleanup.sh                 # Tear down (cluster + bridge; optional: operator)
└── docs/
    ├── ARCHITECTURE.md            # Architecture with Bridge flow
    └── DEPLOYMENT_GUIDE.md        # Step-by-step deployment reference
```

## How It Works

**Slinky** runs Slurm inside OpenShift — the operator reconciles Controller and NodeSet CRs into slurmctld/slurmd pods. The Helm chart also deploys `slurmrestd` (Slurm REST API), which is required by Bridge.

**Slurm Bridge** provides a Kubernetes-native API for job submission. Pods created in namespaces labeled `managed-by-slurm: "true"` are intercepted by Bridge's admission controller and scheduled via Slurm instead of the default Kubernetes scheduler.

**Autoscaler** monitors `squeue` every 30 seconds. By design, when pending jobs need more nodes than are available, it should scale the NodeSet up, and scale back down after 5 idle minutes. In practice, scale-up currently never triggers (see the Quick Start note above and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#autoscaler)) — jobs needing more nodes than exist are rejected by Slurm before reaching `PENDING`, so the autoscaler has nothing to react to. Scale-down still works correctly for whatever replicas exist.

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
- [kannon92/slurm-kueue-ocp](https://github.com/kannon92/slurm-kueue-ocp) — Bridge reference
