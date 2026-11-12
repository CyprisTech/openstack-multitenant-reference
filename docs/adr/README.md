# Architecture decision records

An architecture decision record (ADR) captures one significant design decision: its context, the decision itself and its consequences. A Proposed ADR is revised in place. Once Accepted and released, it is no longer edited: a later decision supersedes it with a new ADR.

ADRs record decisions. The living specification (topology, flows, contracts, sizing) is [docs/concepts/architecture.md](../concepts/architecture.md).

| ADR | Title | Status |
|---|---|---|
| [0001](0001-reference-architecture.md) | Scope and structure of the reference architecture | Accepted; D1 refined by 0003 and 0005, D2 by 0004, D4 by 0002, D7 by 0004; superseded in part by 0006 (D2 for publication, D8) and 0007 (D2 for monitoring) |
| [0002](0002-platform-kubernetes.md) | The `platform` tenant: Kubernetes with Cluster API | Accepted; refined by 0003 (Kubernetes as a tenant type) and 0005 (administration); D5 superseded in part by 0007; lifecycle in scope refined by 0009 |
| [0003](0003-scope-and-boundary.md) | Scope, audience and boundary of the reference | Accepted; D3 and D4 refined by 0009 |
| [0004](0004-planes-and-isolation.md) | Shared planes and isolation between tenants | Accepted |
| [0005](0005-stacks-contracts-and-access.md) | Stacks, contracts between them, and access | Accepted |
| [0006](0006-exposure.md) | Exposure of the tenants | Accepted; supersedes 0001 D2 for publication and D8 for the delivery of routes |
| [0007](0007-monitoring.md) | Observability as a push integration point | Accepted; supersedes 0001 D2 and 0002 D5 for monitoring |
| [0008](0008-tenant-certificates.md) | Certificates of the tenants | Accepted (implemented in v0.4.0); refines 0006 D5 |
| [0009](0009-kubernetes-lifecycle.md) | Kubernetes lifecycle, what the landing zone owns | Accepted; refines 0003 D3 and D4 |
| [0010](0010-kubernetes-shared-services.md) | A Kubernetes cluster for shared services | Accepted; refines 0002, 0006, 0008 |

## Writing an ADR

1. Copy [template.md](template.md) to `NNNN-short-title.md` with the next number.
2. Open a pull request with status *Proposed*.
3. Once merged, the status becomes *Accepted*. Add it to the table above.
