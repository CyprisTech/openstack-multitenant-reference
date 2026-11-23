# Spec: upgrades between releases

- **Status:** Proposed — its release is given in the README's [status](../../README.md#status) (`v0.6`)
- **Related:** [ADR-0017](../adr/0017-upgrades-between-releases.md) (upgrades between releases), [ADR-0009](../adr/0009-kubernetes-lifecycle.md) (Kubernetes lifecycle), [test campaign](../../tests/campaign/README.md), [test procedure](../reference/test-procedure.md), [CHANGELOG](../../CHANGELOG.md) (the migration notes of each release)

## Problem

- **Each release is tested from empty projects only.** The migration notes are written from the plans, not from a run. On 2026-11-20, the upgrade from v0.4.0 to v0.5 failed on every tenant with an egress, while the v0.5.0 notes said the apply replaced the port of the gateway; the release had been published four days before.
- **A release cannot reach an existing cluster.** The manifests and scripts of a cluster reach its bootstrap instance through cloud-init, at creation. The documented way to run a new version, replacing the bootstrap instance and running `create-cluster.sh` again, fails after `clusterctl move`: the new instance has no kubeconfig of the cluster, so the script stops rather than create a second cluster, and the instance is no longer admitted on the cluster's API.

## Goal

- **The release campaign tests the upgrade from the previous release, in one of its two plane modes**: the previous release is deployed without its acceptance, the new one applied over it stack by stack, then the acceptance of the new release runs once. The other mode deploys from empty, as today. The migration notes of the release come from that run.
- **The objects of an existing cluster are updated through its API**, from the administration sources, with the manifests of the stack: `update-cluster.sh`. The bootstrap instance only creates, deletes or repairs a cluster.

Out of scope: upgrades over several releases at once (each release is tested from the one before it); a downgrade; the upgrade of the Kubernetes version of a cluster, tested by the `upgrade` step already; an upgrade by a GitOps pipeline (the integration point of `v0.8`, compatible with this design).

## Design

1. **`update-cluster.sh`**: the part of `create-cluster.sh` that can run again (the cloud configuration Secret, the Gateway API resources, ORC, the ClusterClass and the add-ons, the storage class, the services, the settings of cert-manager), in a script of its own. `create-cluster.sh` creates the cluster, moves it, then calls it. It runs from any host of the administration sources that has the cluster's kubeconfig, with the manifests of the stack's `manifests` output; the stack renders it the same way. When a release changes the versions of the providers, it runs `clusterctl upgrade apply` with the versions of the release, as Cluster API documents ([ADR-0009](../adr/0009-kubernetes-lifecycle.md), D2).
2. **Rolling the machines**: the templates of the ClusterClass are named with a revision of their content; a release that changes a machine gives new templates, and Cluster API replaces the machines one by one. No step of the reference does it.
3. **The previous release, then the new one, in one working tree**: the campaign adds a git worktree at the previous release's tag, under its work directory, and deploys there with that release's own `run.py`: the steps that create the stacks and the clusters and publish the domains, without acceptance, rotation or Kubernetes upgrade. It then checks out the commit under test in the same tree: the states and the inputs, outside git, stay where they are, as for a user who pulls a new release. `run.py --from <tag>`; v0.5.1 is the first release with `run.py`.
4. **Inputs**: `campaign.local.toml` is the same for both; each `run.py` writes the inputs of its own release. An input renamed between releases is part of the migration notes, and the new scenario writes the new one.
5. **The upgrade**, stack by stack in the deployment order: a plan kept in the report with the resources it replaces or destroys, then the apply; after the apply of a Kubernetes stack, `update-cluster.sh` from the campaign host. A load runs during all the applies, as in the Kubernetes upgrade: requests to a published domain through the entry point, and to the shared cluster's internal service. The report lists, per stack, the replaced resources and the requests that failed during its apply: that list is the draft of the migration notes.
6. **Then the scenario of the new release, unchanged**: acceptance, rotation, Kubernetes upgrade, direct exposure, hostile route, empty plans, teardown.
7. **Which mode**: the mode that starts from the previous release alternates from one release to the next, so that both modes go through an upgrade; the test results say which one did.

Its cost: deploying the previous release replaces deploying the new one (about 35 minutes, clusters included, from the durations measured on 2026-11-21, [test procedure](../reference/test-procedure.md#overview)); the upgrade adds a plan and an apply per stack, a few minutes when little is replaced, more when instances or machines are.

## Dependencies and order

1. `update-cluster.sh` (parts 1 and 2), with the README of the Kubernetes stacks and the [Kubernetes lifecycle](../guides/kubernetes-lifecycle.md) guide: useful on its own, it gives the clusters of a deployment a way to take a release.
2. `run.py --from` (parts 3 to 5), tested from v0.5.1.
3. The upgrade in the campaign of each release (parts 6 and 7), first for v0.6.

## Proposed decisions

- **One working tree for both releases**: the states stay in place, as for a user. Set aside: two trees sharing states through a backend override, which tests a layout no user has.
- **`update-cluster.sh` from the administration sources**, not from the bootstrap instance: the cluster manages itself after the move, and its API is the administration path. Set aside: the Terraform Kubernetes provider, which would tie every plan of the stack to the cluster's API being reachable.
- **The report drafts the migration notes**: what is replaced, and whether the services answered, is measured instead of read from a plan.
