# Slurm Bridge on OCP

Deploys Slurm with Slurm Bridge on Red Hat OpenShift using the Slinky operator. Extends [slurm-on-ocp](https://github.com/RHEcosystemAppEng/slurm-on-ocp) with Bridge support and a fully autonomous queue-driven autoscaler.

## What's different from slurm-on-ocp

| | slurm-on-ocp | slurm-bridge-on-ocp |
|---|---|---|
| Deployment | Raw YAML CRs | Helm chart (includes REST API) |
| Slurm REST API | Not deployed | Deployed (required by Bridge) |
| Slurm Bridge | Not included | Included |
| Autoscaler scale-up | Launcher script | Autonomous (queue-driven) |
| Job submission | `oc exec ... sbatch` | `sbatch` direct or via Bridge API |

## Quick Start

```bash
# Prerequisites: oc logged in, helm installed, cert-manager on cluster

# Full deployment (operator + cluster + bridge + autoscaler)
./scripts/deploy.sh

# If operator already installed via OperatorHub
./scripts/deploy.sh --skip-operator

# Verify
./scripts/test-slurm.sh

# Submit a job — autoscaler scales up automatically
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- sbatch --nodes=2 --wrap="hostname && date"
```

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

**Autoscaler** monitors `squeue` every 30 seconds. When pending jobs need more nodes than are available, it scales the NodeSet up. After 5 minutes with no jobs, it scales back down. Any job source triggers this — manual `sbatch`, Bridge, notebooks, or CI pipelines.

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
