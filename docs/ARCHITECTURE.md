# Architecture — Slurm Bridge on OpenShift

## Overview

This project runs a Slurm cluster inside OpenShift using the Slinky operator and exposes it to Kubernetes-native workloads via Slurm Bridge. The POC demonstrates the full path with a PyTorch fine-tuning job submitted as a standard Kubernetes Job.

## Components

| Component | Namespace | Role |
|-----------|-----------|------|
| Slinky Operator | `slinky` | Watches Controller/NodeSet CRs, reconciles Slurm pods |
| slurmctld | `slurm` | Slurm scheduler and job queue |
| slurmrestd | `slurm` | Slurm REST API (required by Bridge) |
| Bridge admission | `slurm` | Intercepts pod creation in labeled namespaces |
| Bridge scheduler | `slurm` | Schedules intercepted pods via Slurm |
| Bridge controllers | `slurm` | Manages Bridge lifecycle |
| OCP worker nodes | cluster | External compute pool (labeled during deploy; GPU nodes require NVIDIA GPU Operator) |

> **Note:** Bridge is installed into the **Slurm cluster namespace** (`slurm`), not the Slinky operator's namespace (`slinky`). Bridge's `Token` CR reads the `slurm-auth-jwt` secret (created by the Slurm Helm chart) and writes the `slurm-bridge-token` secret that Bridge's pods consume — both lookups are same-namespace, so Token, secret, and Bridge pods must all live alongside `slurmrestd` in `slurm`.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  OpenShift Cluster                                                   │
│                                                                      │
│  ┌────────────────────────┐                                         │
│  │  slinky namespace       │                                        │
│  │  ┌──────────────────┐  │                                         │
│  │  │  Slinky Operator │  │                                         │
│  │  │  (watches CRs)   │  │                                         │
│  │  └────────┬─────────┘  │                                         │
│  └───────────┼────────────┘                                         │
│              │ reconciles                                            │
│              ▼                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  slurm namespace                                             │    │
│  │                                                               │    │
│  │  ┌────────────────────────────────┐                          │    │
│  │  │  Slurm Bridge                  │                          │    │
│  │  │  - admission controller        │                          │    │
│  │  │  - scheduler                   │                          │    │
│  │  │  - controllers                  │                          │    │
│  │  └──────────────┬───────────────────┘                        │    │
│  │                 │ REST API calls                              │    │
│  │  ┌──────────────▼──────────────┐  ┌─────────────┐            │    │
│  │  │ slurmctld                    │  │ slurmrestd  │            │    │
│  │  │ (scheduler)                  │◄─┤ (REST API)  │            │    │
│  │  └──────┬───────────────────────┘  └─────────────┘            │    │
│  │         │ schedule jobs                                       │    │
│  │         ▼                                                     │    │
│  │  ┌──────────────────────────────────────────┐                │    │
│  │  │  OCP worker nodes (external-node pool)   │                │    │
│  │  │  labeled during deploy-bridge.sh         │                │    │
│  │  └──────────────────────────────────────────┘                │    │
│  └───────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  text-classifier-demo namespace (managed-by-slurm=true)       │    │
│  │  ┌────────────────────────────────┐                          │    │
│  │  │  K8s Job (torchrun + train.py) │ ──► intercepted by Bridge│    │
│  │  └────────────────────────────────┘                          │    │
│  └───────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

## Job Flow via Slurm Bridge

1. A Kubernetes workload (Job, Pod, pipeline) is created in a namespace labeled `managed-by-slurm: "true"`
2. Bridge's admission controller intercepts the pod creation
3. Bridge translates the pod spec into an sbatch job via the Slurm REST API
4. slurmctld schedules the job onto an external OCP worker node
5. The pod runs on the node; Slurm tracks the job via `squeue`/`sacct`

> **Important (confirmed via live testing):** Bridge's admission controller intercepts **every** pod created in a `managed-by-slurm: "true"` namespace — not just the workload pods you intend to route through Slurm. This includes infrastructure pods you don't control the spec of, like OpenShift's own `BuildConfig` build pods. Those typically need a privileged/`hostPath` security context that Slurm has no way to satisfy, so Bridge repeatedly tries and fails to bind them, and they sit in `Pending` forever with **zero scheduling events**. Keep build/infra namespaces separate from any namespace labeled `managed-by-slurm`.

## Key Differences from slurm-on-ocp

- **Helm-based deployment** — the Slurm chart creates Controller, NodeSet, and RestApi CRs together. The RestApi is required by Bridge.
- **slurmrestd** — exposes Slurm's job submission and monitoring as a REST API. Bridge calls this instead of using `oc exec ... sbatch`.
- **Token CR** — Bridge authenticates to slurmrestd with a JWT token managed by the `Token` CR.
- **Node labeling** — worker OCP nodes need `scheduler.slinky.slurm.net/external-node: "true"` for Bridge to consider them eligible.
- **Kubernetes-native submission** — workloads submit as standard Pods/Jobs; no Slurm CLI knowledge required in the workload definition.
