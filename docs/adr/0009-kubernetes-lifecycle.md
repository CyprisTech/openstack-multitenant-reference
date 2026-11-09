# ADR-0009: Kubernetes lifecycle, what the landing zone owns

- **Status:** Accepted
- **Date:** 2026-11-07
- **Deciders:** maintainers
- **Refines:** [ADR-0003](0003-scope-and-boundary.md) D3 (day-to-day operations of the `kubernetes` tenant) and D4 (in scope: the day-to-day operations of the Kubernetes clusters)

## Context

ADR-0003 puts the day-to-day operations of the Kubernetes clusters in scope: upgrade, scaling, credential rotation. Taken as a whole, this is the job of a Kubernetes distribution or of a managed Kubernetes offer: Cluster API already defines upgrades (a new version in the ClusterClass), scaling and machine remediation; Sovereign Cloud Stack ships cluster stacks; OpenStack operators offer Magnum with its Cluster API driver, Atmosphere among them. A reference maintained by two people cannot track their release cycles, and building tooling around them would move the repository to level 3, which ADR-0003 D4 keeps out.

What no distribution provides is what this architecture adds around a cluster: its attachments to the planes, its entries, its addresses, its credentials and its isolation.

## Options considered

1. **Keep the full day-to-day operations in scope** — the reference becomes a Kubernetes distribution for OpenStack; it competes with maintained projects and ages with every Kubernetes release.
2. **Drop the lifecycle entirely** — a cluster created by the stack would break the architecture at its first upgrade (addresses, admissions) without anyone having checked.
3. **Own only what the landing zone requires from the lifecycle, delegate the rest** — chosen.

## Decision

### D1 — What the reference owns

- The service addresses do not change with the lifecycle: the stack reserves them outside the cluster, so upgrading or replacing nodes and recreating an exposed Service keep them. Changing an address remains a deliberate operation, supported as for any tenant: the domains are published again and the entry point's routes are updated in place ([ADR-0006](0006-exposure.md), D3).
- The address of the API stays with Cluster API, on the load balancer it creates. An upgrade or a node replacement keeps it, as the upgrade test checks. It changes only when the cluster is recreated, which already gives a new kubeconfig.
- The cluster's credential: rotating its application credential without recreating the cluster.
- The administration path during operations: the bootstrap instance admitted again when it must act on the cluster, and only then.
- What `clusterctl move` does not carry for this architecture (the ORC image).
- The certificates of the cluster's domains ([ADR-0008](0008-tenant-certificates.md)).

Each is documented and tested, with one minor Kubernetes upgrade per release cycle as the test.

### D2 — What it delegates

Upgrades, scaling, machine remediation and the backup of etcd are Cluster API's operations on the ClusterClass the stack provides. The reference documents the commands for its ClusterClass and points to Cluster API's documentation; it builds no tooling around them. The ClusterClass takes the node image as a variable, since a Kubernetes version needs its own image.

### D3 — A managed Kubernetes offer replaces the stack

When the cloud operator offers managed Kubernetes (Magnum with the Cluster API driver, a Sovereign Cloud Stack KaaS), a tenant may use it instead of `stacks/tenants/kubernetes`. The architecture requires the same of it: its network attached to the planes through its own routers, its entries at service addresses admitted to the entry point or to its consumers, its sources declared, and its rows in the isolation test. The reference documents this as an integration, without a stack.

## Consequences

- The README's scope and release table name "the lifecycle the landing zone requires" instead of "day-to-day operations".
- A Kubernetes upgrade is tested once per release cycle, not each Kubernetes release.
- Level 3 stays out: after `v1.0`, integrations of platform tools may go in a separate repository, on demand (ADR-0003 D4).
