# Architecture decision records

An architecture decision record (ADR) captures one significant design decision: its context, the decision itself and its consequences. Until the first release, ADRs are revised in place. Once an implementation has been released, an ADR is no longer edited: a later decision supersedes it with a new ADR.

ADRs record decisions. The living specification (topology, flows, contracts, sizing) is [docs/architecture.md](../concepts/architecture.md).

| ADR | Title | Status |
|---|---|---|
| [0001](0001-reference-architecture.md) | Scope and structure of the reference architecture | Accepted; D1–D2 refined by 0003, D4 by 0002 |
| [0002](0002-platform-kubernetes.md) | The `platform` tenant: Kubernetes with Cluster API | Accepted; refined by 0003 (Kubernetes as a tenant type) |
| [0003](0003-scope-and-plane-provisioning.md) | Scope: one account, one project per tenant; how the planes are provided | Proposed |

## Writing an ADR

1. Copy [template.md](template.md) to `NNNN-short-title.md` with the next number.
2. Open a pull request with status *Proposed*.
3. Once merged, the status becomes *Accepted*. Add it to the table above.
