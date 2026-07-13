# Plan

## Objective

Extend [slurm-on-ocp](https://github.com/RHEcosystemAppEng/slurm-on-ocp) with Slurm Bridge
support: a Kubernetes-native demo that explains *why* Slurm Bridge matters for OpenShift/HPC
workloads, not just that it functions. Keep it simple and enablement-focused rather than
maximally complex.

## Phases

1. **Set up Slurm Bridge** — deploy Slinky operator + Slurm cluster + Bridge + autoscaler on
   OCP, verify job routing end-to-end.
2. **Build the practical demo** — fine-tune a pretrained Hugging Face model (text classifier)
   via Slurm Bridge, submitted as a Bridge-routed job.
3. **Run it, tweak, and finalize** — validate it works as expected, iterate, produce an
   architecture diagram + demo video for review.

## Status

**Phase 1: Done, live-tested on a real OCP cluster.**
- Full deploy/cleanup cycle (`scripts/deploy.sh`, `scripts/cleanup.sh`) works end-to-end
- Bridge successfully routes a real pod to Slurm and it runs to completion
- Fixed along the way: Bridge namespace mismatch, missing operator RBAC, no Slurm partition
  ever defined, deprecated autoscaler image, missing SCC for `slurmd`, and bugs in
  `test-slurm.sh`
- Known limitation (documented in `docs/ARCHITECTURE.md`): NodeSet autoscaling doesn't
  actually trigger for direct `sbatch`. Doesn't block Phase 2 — Bridge-routed jobs work from
  zero regardless, using a separate node pool.

**Phase 2: Not started.**

**Phase 3: Not started.**

## Phase 2 in detail — build the practical demo

**Use case:** distributed text classifier fine-tuning. Take a pretrained Hugging Face model
(baseline accuracy ~25%) plus a small labeled text dataset (≤~500MB, so it doesn't bloat the
repo), and fine-tune it via Slurm Bridge as an HPC-style training job, targeting ~80% accuracy.
This was picked over an image-generation alternative specifically because of dataset size and
because a text classifier is a simpler, more relatable "why do I need this" story.

**Why through Bridge, not raw `sbatch`:** the whole point of this repo (vs. plain
`slurm-on-ocp`) is proving Slurm Bridge's Kubernetes-native path. The training job must be
submitted as a Pod/Job in a `managed-by-slurm: "true"` namespace (like `demos/kueue_demo.sh`
does, minus the Kueue layer), not via `oc exec ... sbatch`.

**Concrete deliverables:**
- Fine-tuning script in `training/` (currently empty except `.gitkeep`) — reuse the structural
  pattern from the old `slurm-on-ocp` DDP example (distributed setup, checkpoint/metrics
  saving) but swap the synthetic CNN for a Hugging Face model + real text data
- A demo entrypoint script (e.g. `demos/text-classifier-demo.sh`), modeled on
  `kueue_demo.sh`: labels the namespace, submits the training Job, monitors it, tears down
- Namespace/resource requests sized correctly (GPU vs. CPU — decide and flag to Swati if the
  cluster needs anything provisioned)
- A short doc update describing the use case and why Bridge is the right layer for it

**Before writing code:** a quick heads-up to Swati on the model/dataset choice is enough —
she already informally greenlit "idea 1" (the text classifier) in the July 9 1:1.

**Guardrails (per Swati's direction):** keep this simple — don't scale up complexity before
this version works end-to-end. Resist scope creep toward the more elaborate ideas in the demo
ideas doc until this baseline is solid.

## Phase 3 in detail — run it, tweak, and finalize

- Validate the fine-tuning actually improves accuracy as expected (~25% → ~80%)
- Confirm scaling/resource behavior makes sense for a *real* training workload, not just the
  busybox-style timing used in `kueue_demo.sh`
- Iterate on the demo before locking it in as "the" version to show
- Consider layering in OpenShift AI / a Jupyter notebook for part of the demo (Swati
  specifically suggested this, to showcase more of the Red Hat AI stack)
- Produce the downstream deliverables Swati asked for: an updated architecture diagram and an
  end-to-end demo video (deploy → trigger job → observe changes on OpenShift → results)
- Logical stopping point: before the intern expo / before internship wraps — no hard deadline,
  but should reach a clean, presentable state
- Optional: present at the team's AI knowledge-sharing meeting once ready
