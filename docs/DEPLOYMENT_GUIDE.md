# Deployment Guide — Slurm Bridge on OpenShift

## Prerequisites

- OpenShift 4.x cluster with admin access
- `oc` CLI installed and logged in (`oc login`)
- `helm` 3.x installed
- cert-manager installed on the cluster (required by Slinky operator)

```bash
# Verify
oc whoami
helm version
oc get pods -n cert-manager
```

If cert-manager is not installed, install it via OperatorHub (recommended) or Helm:
```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true --version v1.13.0 --wait --timeout 5m
```

---

## Option A: Automated (Recommended)

```bash
# Full deployment
./scripts/deploy.sh

# If Slinky operator already installed via OperatorHub
./scripts/deploy.sh --skip-operator

# Custom namespaces
./scripts/deploy.sh --namespace my-slurm --operator-ns slinky
```

The script deploys all four components in order and waits for each to be ready.

---

## Option B: Manual Steps

### Step 1: Install Slinky Operator

```bash
./scripts/deploy-operator.sh

# Or manually via Helm:
helm upgrade --install slurm-operator-crds \
  oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --namespace slinky --create-namespace --server-side=false

helm upgrade --install slurm-operator \
  oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace slinky --create-namespace --wait --timeout 5m

# Verify
oc get pods -n slinky -l app.kubernetes.io/name=slurm-operator
```

### Step 2: Deploy Slurm Cluster

```bash
./scripts/deploy-slurm.sh

# Or manually:
oc create namespace slurm
oc adm policy add-scc-to-user anyuid -z default -n slurm
# slurmd needs privileged mode + BPF/NET_ADMIN/SYS_ADMIN capabilities (cgroup +
# process/network management). Without this, NodeSet pods are rejected by OCP's
# SCC admission and the NodeSet can never scale above 0 replicas.
oc adm policy add-scc-to-user privileged -z default -n slurm

helm upgrade --install slurm \
  oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace slurm --version 1.2.0 \
  -f configs/slurm-values.yaml

# Wait for controller and REST API
oc rollout status statefulset/slurm-controller -n slurm --timeout=300s
oc rollout status deployment/slurm-restapi -n slurm --timeout=300s

# Verify Slurm is functional
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- sinfo
```

### Step 3: Deploy Slurm Bridge

```bash
./scripts/deploy-bridge.sh

# Or manually:
# 0. RBAC patch for the Slinky operator (OCP workaround). The Token controller
#    creates a Secret owned by the Token CR with blockOwnerDeletion=true, which
#    Kubernetes only allows if the operator has "update" on the finalizers
#    subresource of the owner's kind. The operator's default ClusterRole only
#    grants plain "secrets" permissions, not "secrets/finalizers" — without this
#    patch, the Token controller fails every reconcile with "cannot set
#    blockOwnerDeletion if an ownerReference refers to a resource you can't set
#    finalizers on" and never creates "slurm-bridge-token", so all Bridge pods
#    stay stuck with "secret not found". Apply before the Token CR so the first
#    reconcile succeeds instead of waiting through backoff retries.
oc patch clusterrole slurm-operator \
  --type='json' \
  -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["secrets/finalizers"],"verbs":["update"]}}]'

# 1. Apply JWT token CR (Bridge authenticates to slurmrestd)
oc apply -f configs/token.yaml

# 2. Install Bridge via Helm — into the "slurm" namespace, NOT "slinky".
#    Bridge's Token CR reads the "slurm-auth-jwt" secret from its own
#    namespace, and that secret only exists where the Slurm Helm chart
#    created it (the cluster namespace). Installing into "slinky" leaves
#    the Token controller unable to find it, so Bridge pods fail with
#    "secret \"slurm-bridge-token\" not found".
helm upgrade --install slurm-bridge \
  oci://ghcr.io/slinkyproject/charts/slurm-bridge \
  --namespace slurm --create-namespace \
  -f configs/slurm-bridge-values.yaml

oc rollout status deployment/slurm-bridge-admission -n slurm --timeout=300s
oc rollout status deployment/slurm-bridge-controllers -n slurm --timeout=300s
oc rollout status deployment/slurm-bridge-scheduler -n slurm --timeout=300s

# 3. RBAC patch for the Bridge scheduler (separate OCP workaround — may be fixed in Bridge v1.1.1+)
oc patch clusterrole slurm-bridge-scheduler \
  --type='json' \
  -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["pods/finalizers"],"verbs":["update","patch"]}}]'

# 4. Label worker nodes for Bridge scheduling
for node in $(oc get nodes -o name -l node-role.kubernetes.io/worker='' | head -3); do
  oc patch "$node" \
    -p '{"metadata":{"labels":{"scheduler.slinky.slurm.net/external-node":"true"},"annotations":{"scheduler.slinky.slurm.net/external-node-partitions":"all"}}}' \
    --type=merge
done
```

### Step 4: Deploy Autoscaler

```bash
./scripts/deploy-autoscale.sh

# Monitor autoscaler
oc logs -n slurm -l app.kubernetes.io/name=slurm-autoscaler -f
```

---

## Verification

```bash
# Check all components (Bridge lives in the "slurm" namespace, alongside slurmctld/slurmrestd)
oc get pods -n slurm
oc get pods -n slurm | grep bridge
```

> **Note:** `./scripts/test-slurm.sh` (its default "quick" mode) currently fails on a fresh
> deployment — it submits an `sbatch` job immediately, before any `slinky-N` worker has ever
> registered, and hits the same rejection described below. This script has not yet been
> updated to account for that; don't treat a failure there as a sign your deployment is
> broken.

Submit a job through Bridge to confirm the end-to-end path works (this is the path that
actually functions out of the box — see the caveat below for why a plain `sbatch` example
isn't shown here):

```bash
oc label namespace default managed-by-slurm=true
oc run bridge-test --image=quay.io/prometheus/busybox --restart=Never \
  --overrides='{"metadata":{"annotations":{"slurmjob.slinky.slurm.net/account":"slurm","slurmjob.slinky.slurm.net/partition":"all"}}}' \
  -- sh -c "hostname && date"

# Confirm it ran as a Slurm job
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- squeue
oc logs bridge-test
```

**Do not expect a plain `sbatch --nodes=N ...` example to demonstrate autoscaling** — under
this chart's default config (`MIN_REPLICAS=0`, no NodeSet workers registered yet), Slurm
rejects such a request immediately (`Requested node configuration is not available`) instead
of queuing it `PENDING`, so the autoscaler never gets a chance to react. This was confirmed by
live testing, not just code review. See
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md#autoscaler) for the full explanation and what
`sbatch` behavior to actually expect.

---

## Using Slurm Bridge

To submit jobs through Bridge (instead of direct sbatch), label the workload namespace:

```bash
oc label namespace <your-namespace> managed-by-slurm=true
```

Pods created in that namespace will be intercepted by Bridge and scheduled via Slurm.

---

## Cleanup

```bash
# Remove cluster + bridge (keep operator for reuse)
./scripts/cleanup.sh

# Full uninstall
./scripts/cleanup.sh --remove-operator
```

---

## Troubleshooting

**Bridge pods not starting:**
```bash
oc describe pod -n slurm -l app.kubernetes.io/name=slurm-bridge
# Common causes:
#  - cert-manager not ready, or token CR applied before slurmrestd was up
#  - Bridge/Token CR installed into the wrong namespace (must be "slurm", not "slinky") —
#    check for "secret \"slurm-bridge-token\" not found" in pod events:
oc get events -n slurm --sort-by=.lastTimestamp | grep -i "slurm-bridge-token"
```

**slurmrestd not reachable by Bridge:**
```bash
oc get svc -n slurm | grep restapi
oc logs -n slurm -l app.kubernetes.io/name=slurm-bridge-controllers
```

**Autoscaler not scaling up:**

This is expected, not a misconfiguration you need to debug — see the "Known limitation" note
in [`docs/ARCHITECTURE.md`](ARCHITECTURE.md#autoscaler). In short: a direct `sbatch` job
requesting more nodes than are currently registered gets rejected by Slurm immediately
(`Requested node configuration is not available`) instead of going `PENDING`, so the
autoscaler — which only reacts to `PENDING` jobs in `squeue` — never has anything to scale up
in response to. This happens regardless of whether the NodeSet starts at 0 or already has
workers registered.

```bash
oc logs -n slurm -l app.kubernetes.io/name=slurm-autoscaler --tail=30
# If you see repeated "IDLE: no jobs" with no PENDING jobs ever appearing in squeue even
# though you submitted one, that confirms the job was rejected at submission, not queued:
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- squeue
```

Workarounds: submit through Bridge instead (works from zero, see Verification above), or
manually scale first — `oc scale nodeset slurm-worker-slinky -n slurm --replicas=N` — then
submit a job that fits within N nodes.

**RBAC patch warning:**
If the Bridge scheduler pod is crashing with permission errors, reapply the patch:
```bash
./scripts/deploy-bridge.sh  # re-running is idempotent
```
