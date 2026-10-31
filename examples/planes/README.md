# Where the planes come from

The only file that depends on the cloud is the `terraform.tfvars` of [`stacks/shared/planes`](../../stacks/shared/planes/README.md). Every other stack takes its `plane_attachment` from that stack's `attachments` output, in the same shape whatever provides the planes ([How a tenant joins a plane](../../docs/concepts/plane-attachment.md)).

| Your cloud | Example | Planes are | Tenants are seen on them |
|---|---|---|---|
| Private or sovereign, the operator provides the planes | [`operator.tfvars.example`](operator.tfvars.example) | the operator's external networks, adopted | through floating IPs (ranges may overlap) |
| Public, you have a member role | [`hub.tfvars.example`](hub.tfvars.example) | private networks of a hub project, shared by RBAC, with a transit router | at their own addresses (ranges must not overlap) |

The two can be mixed plane by plane. Order and checkpoints: [getting started](../../docs/getting-started/README.md).
