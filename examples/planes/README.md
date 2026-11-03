# Where the planes come from

The only file that depends on the cloud is the `terraform.tfvars` of [`stacks/shared/planes`](../../stacks/shared/planes/README.md). Every other stack takes its `plane_attachment` from that stack's `attachments` output, in the same shape whatever provides the planes ([How a tenant joins a plane](../../docs/concepts/plane-attachment.md)).

| Your cloud | Example | Planes are | Tenants are seen on them |
|---|---|---|---|
| Private or sovereign, the cloud operator provides the planes | [`operator.tfvars.example`](operator.tfvars.example) | the cloud operator's external networks, adopted | at their router's address (source NAT); a floating IP for what others must reach (ranges may overlap) |
| Public, you have a member role | [`hub.tfvars.example`](hub.tfvars.example) | private networks of a hub project, shared by RBAC, with a transit router | at their own addresses (ranges must not overlap) |

The examples declare the three planes of the reference scenario; `shared/planes` takes any number of planes, and the two kinds can be mixed. A third kind, operator planes routed in a shared address scope (no address translation), comes with `cloud-baseline` ([ADR-0004](../../docs/adr/0004-planes-and-isolation.md), D1).

The two can be mixed plane by plane. Order and checkpoints: [getting started](../../docs/getting-started/README.md).
