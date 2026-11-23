# ADR-0017: Upgrades between releases

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** maintainers
- **Refines:** [ADR-0009](0009-kubernetes-lifecycle.md) (Kubernetes lifecycle), [ADR-0002](0002-platform-kubernetes.md) (the bootstrap instance)
- **Supersedes, once accepted:** [ADR-0009](0009-kubernetes-lifecycle.md) D1 for the administration path during operations (D3 below)

## Context

A user of the reference moves from one release to the next by applying the new stacks over their deployment, following the migration notes of the release. Two facts:

- Each release is tested from empty projects. The notes are read from the plans. On 2026-11-20, the upgrade from v0.4.0 to v0.5 failed on every tenant with an egress, four days after the release, while its notes said the apply replaced a port.
- A release cannot reach an existing Kubernetes cluster. Its manifests and scripts reach the bootstrap instance through cloud-init, at creation; ADR-0009 D1 makes that instance the administration path during operations, admitted again when it must act on the cluster. After `clusterctl move`, a new bootstrap instance has no kubeconfig of the cluster and is no longer admitted on its API: the documented way to run a new version does not work.

## Options considered

For the test:

1. **Notes from the plans** (until now): the failure of 2026-11-20 shows their limit.
2. **An upgrade run added to the release campaign**, next to both modes from empty: it doubles the deployment of a release campaign.
3. **One of the two plane modes from the previous release** (chosen): the previous release is deployed instead of the new one, without its acceptance, and the acceptance of the new release runs once, on the upgraded deployment.

For the clusters:

- **A new bootstrap instance at each release**, given the cluster's kubeconfig and admitted again on its API: an instance and an admission to create and remove at each release, for objects the cluster already manages.
- **Through the cluster's API, from the administration sources** (chosen): the cluster manages itself after the move; its objects are declarative and applied to it like any manifest.
- **The Terraform Kubernetes provider**: every plan of the stack would depend on the cluster's API being reachable, and the state would hold the cluster's objects.
- **A GitOps pipeline pulling the manifests**: the integration point of `v0.8`, compatible with the chosen option, not a requirement.

## Decision

### D1 — Upgrades are tested from the previous release only

Each release is tested from the one before it. A user who skips releases applies the notes of each one, in turn.

### D2 — A release campaign deploys one plane mode from the previous release

One mode starts from empty projects; the other deploys the previous release, applies the new one stack by stack under load, then runs the acceptance of the new release. The mode that starts from the previous release alternates between releases. The resources each stack replaces, and the requests that failed during its apply, are measured: the migration notes of the release come from them.

### D3 — The objects of an existing cluster are updated through its API

After `clusterctl move`, the administration path of a cluster during operations is its API, from the administration sources: a script, `update-cluster.sh`, applies the manifests of the stack to the cluster and, when a release changes them, upgrades the providers with `clusterctl`. The bootstrap instance only creates a cluster, deletes it, or repairs one that can no longer manage itself (ADR-0002).

## Consequences

- `create-cluster.sh` creates and moves the cluster, then calls `update-cluster.sh`; the README of the Kubernetes stacks and the Kubernetes lifecycle guide describe how a cluster takes a release.
- The campaign can deploy a previous release and apply the commit under test over it (`run.py --from`); the test results say which mode went through the upgrade.
- The CHANGELOG's migration notes are drafted from the report of the release campaign.
- ADR-0009 D1 keeps what the reference owns, except the administration path, which this ADR supersedes once accepted.
