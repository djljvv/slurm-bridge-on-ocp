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
# 1. Apply JWT token CR (Bridge authenticates to slurmrestd)
oc apply -f configs/token.yaml

# 2. Install Bridge via Helm
helm upgrade --install slurm-bridge \
  oci://ghcr.io/slinkyproject/charts/slurm-bridge \
  --namespace slinky --create-namespace \
  -f configs/slurm-bridge-values.yaml

oc rollout status deployment/slurm-bridge-admission -n slinky --timeout=300s
oc rollout status deployment/slurm-bridge-controllers -n slinky --timeout=300s
oc rollout status deployment/slurm-bridge-scheduler -n slinky --timeout=300s

# 3. RBAC patch (OCP workaround — may be fixed in Bridge v1.1.1+)
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
# Cluster health
./scripts/test-slurm.sh

# Check all components
oc get pods -n slurm
oc get pods -n slinky | grep bridge

# Submit a test job (autoscaler will scale up automatically)
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- sbatch --nodes=2 --wrap="hostname && date && sleep 10"

# Watch autoscaler react
oc logs -n slurm -l app.kubernetes.io/name=slurm-autoscaler -f --tail=20

# Watch pods scale up
watch -n 5 'oc get pods -n slurm'
```

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
oc describe pod -n slinky -l app.kubernetes.io/name=slurm-bridge
# Common cause: cert-manager not ready, or token CR applied before slurmrestd was up
```

**slurmrestd not reachable by Bridge:**
```bash
oc get svc -n slurm | grep restapi
oc logs -n slinky -l app.kubernetes.io/name=slurm-bridge-controllers
```

**Autoscaler not scaling up:**
```bash
oc logs -n slurm -l app.kubernetes.io/name=slurm-autoscaler --tail=30
# Check: is the controller pod reachable? Does squeue show PENDING jobs?
CTRL=$(oc get pods -n slurm -l app.kubernetes.io/name=slurmctld -o jsonpath='{.items[0].metadata.name}')
oc exec -n slurm $CTRL -c slurmctld -- squeue
```

**RBAC patch warning:**
If the Bridge scheduler pod is crashing with permission errors, reapply the patch:
```bash
./scripts/deploy-bridge.sh  # re-running is idempotent
```
