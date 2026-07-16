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

The script deploys all three components in order and waits for each to be ready.

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

# 5. (Optional) Label GPU nodes for Bridge scheduling
#    The loop above only labels the first 3 generic worker nodes. If you plan
#    to run GPU workloads (--gpu flag in the demo script), the GPU nodes must
#    also be labeled — otherwise Bridge has nowhere to place pods that request
#    nvidia.com/gpu and they stay Pending with "Insufficient nvidia.com/gpu".
for node in $(oc get nodes -o jsonpath='{range .items[?(@.status.capacity.nvidia\.com/gpu)]}{.metadata.name}{"\n"}{end}'); do
  oc patch "node/$node" \
    -p '{"metadata":{"labels":{"scheduler.slinky.slurm.net/external-node":"true"},"annotations":{"scheduler.slinky.slurm.net/external-node-partitions":"all"}}}' \
    --type=merge
done
```

---

## Verification

```bash
# Check all components (Bridge lives in the "slurm" namespace, alongside slurmctld/slurmrestd)
oc get pods -n slurm
oc get pods -n slurm | grep bridge
```

Submit a job through Bridge to confirm the end-to-end path works:

```bash
oc project default
oc label namespace default managed-by-slurm=true --overwrite
oc delete pod bridge-test -n default --ignore-not-found
oc run bridge-test -n default --image=quay.io/prometheus/busybox --restart=Never \
  --overrides='{"metadata":{"annotations":{"slurmjob.slinky.slurm.net/account":"slurm","slurmjob.slinky.slurm.net/partition":"all"}}}' \
  -- sh -c "hostname && date"

# Wait for Bridge to schedule the pod through Slurm and for the container to finish
oc wait --for=condition=Ready pod/bridge-test -n default --timeout=120s 2>/dev/null || true
oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/bridge-test -n default --timeout=120s

# Confirm it ran as a Slurm job
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- squeue
oc logs bridge-test -n default
```

Run the PyTorch demo:

```bash
# CPU
./demos/text-classifier-demo.sh --image <your-training-image>

# GPU (requires NVIDIA GPU Operator on cluster)
./demos/text-classifier-demo.sh --image <your-training-image> --gpu 1
```

See [`docs/DEMO.md`](DEMO.md) for image build instructions.

---

## Using Slurm Bridge

To submit jobs through Bridge, label the workload namespace:

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

**GPU pods stuck in Pending ("Insufficient nvidia.com/gpu"):**
The deploy script only labels the first 3 generic worker nodes as Bridge external nodes.
GPU nodes need the label too, or Bridge can't schedule GPU workloads onto them:
```bash
for node in $(oc get nodes -o jsonpath='{range .items[?(@.status.capacity.nvidia\.com/gpu)]}{.metadata.name}{"\n"}{end}'); do
  oc patch "node/$node" \
    -p '{"metadata":{"labels":{"scheduler.slinky.slurm.net/external-node":"true"},"annotations":{"scheduler.slinky.slurm.net/external-node-partitions":"all"}}}' \
    --type=merge
done
```

**RBAC patch warning:**
If the Bridge scheduler pod is crashing with permission errors, reapply the patch:
```bash
./scripts/deploy-bridge.sh  # re-running is idempotent
```
