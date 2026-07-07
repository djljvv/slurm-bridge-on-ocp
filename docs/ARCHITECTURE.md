# Architecture — Slurm Bridge on OpenShift

## Overview

This project runs a Slurm cluster inside OpenShift using the Slinky operator, and exposes it to Kubernetes-native workloads via Slurm Bridge. A queue-driven autoscaler scales the worker NodeSet up and down based on actual job demand.

## Components

| Component | Namespace | Role |
|-----------|-----------|------|
| Slinky Operator | `slinky` | Watches Controller/NodeSet CRs, reconciles Slurm pods |
| slurmctld | `slurm` | Slurm scheduler and job queue |
| slurmd pods | `slurm` | Compute workers (NodeSet, scales 0–MAX_REPLICAS) |
| slurmrestd | `slurm` | Slurm REST API (required by Bridge) |
| Bridge admission | `slinky` | Intercepts pod creation in labeled namespaces |
| Bridge scheduler | `slinky` | Schedules intercepted pods via Slurm |
| Bridge controllers | `slinky` | Manages Bridge lifecycle |
| Autoscaler | `slurm` | Polls squeue, scales NodeSet to match demand |

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  OpenShift Cluster                                                   │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  slinky namespace                                           │    │
│  │                                                             │    │
│  │  ┌──────────────────┐    ┌────────────────────────────────┐ │    │
│  │  │  Slinky Operator │    │  Slurm Bridge                  │ │    │
│  │  │  (watches CRs)   │    │  - admission controller        │ │    │
│  │  └────────┬─────────┘    │  - scheduler                   │ │    │
│  │           │              │  - controllers                  │ │    │
│  └───────────┼──────────────┴──────────────┬───────────────────┘    │
│              │                             │                         │
│              ▼                             │ REST API calls          │
│  ┌─────────────────────────────────────┐   │                         │
│  │  slurm namespace                   │   │                         │
│  │                                    │◄──┘                         │
│  │  ┌─────────────┐  ┌─────────────┐  │                             │
│  │  │ slurmctld   │  │ slurmrestd  │  │                             │
│  │  │ (scheduler) │  │ (REST API)  │  │                             │
│  │  └──────┬──────┘  └─────────────┘  │                             │
│  │         │                          │                             │
│  │         │ schedule jobs            │                             │
│  │         ▼                          │                             │
│  │  ┌──────────┐ ┌──────────┐         │                             │
│  │  │ slurmd-0 │ │ slurmd-N │  ◄──── autoscaler                    │
│  │  │ (worker) │ │ (worker) │  (scales 0 → MAX on queue demand)    │
│  │  └──────────┘ └──────────┘         │                             │
│  └─────────────────────────────────────┘                             │
└─────────────────────────────────────────────────────────────────────┘
```

## Job Flow

### Direct submission (sbatch)
1. User runs `oc exec -n slurm <controller> -c slurmctld -- sbatch --nodes=N job.sh`
2. Slurm queues the job; job goes to PENDING
3. Autoscaler detects PENDING job needing N nodes, scales NodeSet to N
4. Slinky creates slurmd pods; they register with slurmctld
5. Slurm atomically allocates all N nodes and starts the job
6. After completion, autoscaler scales down after idle period

### Via Slurm Bridge
1. Kubernetes workload (notebook, pipeline, web service) creates a Pod in a namespace labeled `managed-by-slurm: "true"`
2. Bridge admission controller intercepts the Pod creation
3. Bridge translates the Pod spec into an sbatch job via the Slurm REST API
4. From here, same flow as direct submission (steps 2–6 above)

## Autoscaler

The autoscaler runs as a Deployment in the `slurm` namespace. Every `POLL_INTERVAL` seconds it:

1. Queries `squeue -h -t PENDING -o "%i %D"` and `squeue -h -t RUNNING -o "%i %D"`
2. If the max node count requested by any job exceeds current NodeSet replicas → scale up
3. If no jobs for `SCALE_DOWN_DELAY` seconds → scale down to `MIN_REPLICAS`
4. If squeue query fails (controller unreachable) → skip the cycle, do not scale

`MIN_REPLICAS` defaults to 0 in this repo — workers only exist while jobs are running.

## Key Differences from slurm-on-ocp

- **Helm-based deployment** — the Slurm chart creates Controller, NodeSet, and RestApi CRs together. The RestApi is new and required by Bridge.
- **slurmrestd** — exposes Slurm's job submission and monitoring as a REST API. Bridge calls this instead of using `oc exec ... sbatch`.
- **Token CR** — Bridge authenticates to slurmrestd with a JWT token managed by the `Token` CR.
- **Node labeling** — worker OCP nodes need `scheduler.slinky.slurm.net/external-node: "true"` for Bridge to consider them eligible.
- **Autonomous scale-up** — the autoscaler now handles both scale-up and scale-down. No launcher code needed in the training workload.
