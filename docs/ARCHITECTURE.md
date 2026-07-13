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
| Bridge admission | `slurm` | Intercepts pod creation in labeled namespaces |
| Bridge scheduler | `slurm` | Schedules intercepted pods via Slurm |
| Bridge controllers | `slurm` | Manages Bridge lifecycle |
| Autoscaler | `slurm` | Polls squeue, scales NodeSet to match demand |

> **Note:** Bridge is installed into the **Slurm cluster namespace** (`slurm`), not the Slinky operator's namespace (`slinky`). Bridge's `Token` CR reads the `slurm-auth-jwt` secret (created by the Slurm Helm chart) and writes the `slurm-bridge-token` secret that Bridge's pods consume — both lookups are same-namespace, so Token, secret, and Bridge pods must all live alongside `slurmrestd` in `slurm`. Installing Bridge into `slinky` leaves the Token controller unable to find the JWT secret, so Bridge pods fail with `secret "slurm-bridge-token" not found`.

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
│  │  ┌──────────┐ ┌──────────┐                                    │    │
│  │  │ slurmd-0 │ │ slurmd-N │  ◄──── autoscaler                  │    │
│  │  │ (worker) │ │ (worker) │  (scales 0 → MAX on queue demand)  │    │
│  │  └──────────┘ └──────────┘                                    │    │
│  └───────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

## Job Flow

### Direct submission (sbatch)
This is the **intended** design. Steps 2–3 do not currently happen in practice — see the
"Known limitation" note under [Autoscaler](#autoscaler) below.

1. User runs `oc exec -n slurm <controller> -c slurmctld -- sbatch --nodes=N job.sh`
2. ~~Slurm queues the job; job goes to PENDING~~ — in practice, Slurm rejects the job at
   submission time if N exceeds currently-registered nodes; it never reaches PENDING.
3. ~~Autoscaler detects PENDING job needing N nodes, scales NodeSet to N~~ — never triggered,
   since step 2 never produces a PENDING job to react to.
4. Slinky creates slurmd pods; they register with slurmctld (works if you scale the NodeSet
   manually, e.g. `oc scale nodeset slurm-worker-slinky --replicas=N`)
5. Slurm atomically allocates all N nodes and starts the job (works once nodes from step 4
   are registered and idle)
6. After completion, autoscaler scales down after idle period (this part does work)

### Via Slurm Bridge
1. Kubernetes workload (notebook, pipeline, web service) creates a Pod in a namespace labeled `managed-by-slurm: "true"`
2. Bridge admission controller intercepts the Pod creation
3. Bridge translates the Pod spec into an sbatch job via the Slurm REST API
4. From here, same flow as direct submission (steps 2–6 above)

## Autoscaler

The autoscaler runs as a Deployment in the `slurm` namespace. Every `POLL_INTERVAL` seconds it:

1. Queries `squeue -h -t PENDING -o "%i %D"` and `squeue -h -t RUNNING -o "%i %D"`
2. If the max node count requested by any `PENDING` job exceeds current NodeSet replicas →
   scale up (**this never actually fires in practice** — see limitation below; verified live
   on a real OCP cluster, not just by reading the code)
3. If no jobs for `SCALE_DOWN_DELAY` seconds → scale down to `MIN_REPLICAS` (this part works)
4. If squeue query fails (controller unreachable) → skip the cycle, do not scale

`MIN_REPLICAS` defaults to 0 in this repo — workers only exist while jobs are running (in
theory; see below).

> **Known limitation (confirmed by live testing, not just code inspection): scale-up never
> triggers for direct `sbatch`, regardless of starting replica count.**
>
> The autoscaler's whole design depends on a job reaching `PENDING` in `squeue` when it needs
> more nodes than currently exist. In practice, Slurm rejects such jobs immediately at
> submission time — `sbatch: error: Batch job submission failed: Requested node configuration
> is not available` — and they never reach `PENDING`. This was tested and confirmed in two
> scenarios:
> - **0 replicas, request N nodes:** rejected immediately (no node of that type has ever
>   registered, so Slurm has no way to know one *could* exist).
> - **1 replica already registered (`slinky-0`), request `--nodes=2-8`:** *also* rejected
>   immediately, even with an existing idle node in the partition. Slurm will not queue a job
>   whose upper bound it can't currently satisfy from already-registered nodes.
>
> Since the job never reaches `PENDING`, the autoscaler — which only reacts to `PENDING` jobs
> — never has anything to scale up in response to. This is a fundamental gap in the current
> chart configuration, not a transient issue: Slurm only accepts requests it can satisfy from
> nodes it already knows about (registered, or explicitly pre-declared as `CLOUD`/`FUTURE`
> state in `slurm.conf`). This repo's Slurm values don't declare any such placeholder nodes,
> so there is no way for slurmctld to accept a speculative request pending future capacity.
>
> **What does work:** Bridge-routed jobs (Pods in a `managed-by-slurm: "true"` namespace) are
> scheduled onto a *separate*, statically-sized pool of "external nodes" (the underlying OCP
> worker nodes labeled during `deploy-bridge.sh`) — independent of NodeSet replica count
> entirely. This is why Bridge jobs succeed "from zero" while direct `sbatch` doesn't: Bridge
> isn't actually exercising the NodeSet autoscaling path at all, it's using a different,
> fixed-size resource pool.
>
> **To make direct-`sbatch` autoscaling actually work**, you'd need to configure Slurm's
> dynamic/`CLOUD` node support (pre-declaring potential `slinky-N` nodes in `slurm.conf` with
> `State=CLOUD` or similar, so slurmctld can accept and queue a job that assumes a node will
> register later) — a real feature addition to the Slurm chart values, not a quick config
> tweak. Alternatively, keep `MIN_REPLICAS` ≥ 1 and only rely on scale-down; genuine scale-up
> under demand would still need the above.

## Key Differences from slurm-on-ocp

- **Helm-based deployment** — the Slurm chart creates Controller, NodeSet, and RestApi CRs together. The RestApi is new and required by Bridge.
- **slurmrestd** — exposes Slurm's job submission and monitoring as a REST API. Bridge calls this instead of using `oc exec ... sbatch`.
- **Token CR** — Bridge authenticates to slurmrestd with a JWT token managed by the `Token` CR.
- **Node labeling** — worker OCP nodes need `scheduler.slinky.slurm.net/external-node: "true"` for Bridge to consider them eligible.
- **Autonomous scale-up** — the autoscaler now handles both scale-up and scale-down. No launcher code needed in the training workload.
