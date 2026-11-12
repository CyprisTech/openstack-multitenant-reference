# Specs

A spec describes work that has not been delivered yet: the problem, the goal, the design, the order of the steps and the questions still open. It is written when the work starts, so that the design can be reviewed before the code.

Specs and [ADRs](../adr/README.md) play different parts:

| | Spec | ADR |
|---|---|---|
| Describes | how a piece of work will be built | one significant decision and its reasons |
| Lives | until the work is delivered | for good, superseded by a later ADR if needed |
| Edited | freely, as the design matures | in place while *Proposed*, never once *Accepted* and released |

## Life cycle

1. **Proposed.** Copy [template.md](template.md) to `short-title.md`, open a pull request, add it to the table below. Its release is given in the README's [status](../../README.md#status), nowhere else.
2. **In progress.** When the work starts, the spec's proposed decisions become an ADR; the spec links to it and keeps the design details.
3. **Delivered.** The design moves into the living documentation ([architecture](../concepts/architecture.md), [reference](../reference)), the guides and the stacks' READMEs; the spec is deleted in the same pull request. The ADR and the git history keep the reasons.

| Spec | Status |
|---|---|
| [A Kubernetes cluster for shared services](kubernetes-shared-services.md) | Implemented in v0.4 ([ADR-0010](../adr/0010-kubernetes-shared-services.md)) |
| [Certificates of the tenants](tenant-certificates.md) | Implemented in v0.4 ([ADR-0008](../adr/0008-tenant-certificates.md)) |
