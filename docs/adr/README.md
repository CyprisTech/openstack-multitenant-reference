# Architecture decision records

An architecture decision record (ADR) captures one significant design decision: its context, the decision itself and its consequences. Until the first release, ADRs are revised in place. Once an implementation has been released, an ADR is no longer edited: a later decision supersedes it with a new ADR.

ADRs record decisions. The living specification (topology, flows, contracts, sizing) is [docs/architecture.md](../architecture.md).

| ADR | Title | Status |
|---|---|---|
| [0001](0001-reference-architecture.md) | Scope and structure of the reference architecture | Proposed |

## Writing an ADR

1. Copy [template.md](template.md) to `NNNN-short-title.md` with the next number.
2. Open a pull request with status *Proposed*.
3. Once merged, the status becomes *Accepted*. Add it to the table above.
