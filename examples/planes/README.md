# Where the planes come from

The only file that depends on the cloud is the `terraform.tfvars` of [`stacks/shared/planes`](../../stacks/shared/planes/README.md). Every other stack takes its `plane_attachment` from that stack's `attachments` output, in the same shape whatever provides the planes ([How a tenant joins a plane](../../docs/concepts/plane-attachment.md)).

| What your cloud gives | Example | Planes are | Tenants are seen on them |
|---|---|---|---|
| External networks of the operator for the planes | [`operator.tfvars.example`](operator.tfvars.example) | the cloud operator's external networks, adopted | at their router's address (source NAT); a floating IP for what others must reach (ranges may overlap) |
| A member role only, on a public or a private cloud | [`hub.tfvars.example`](hub.tfvars.example) | private networks of a hub project, shared by RBAC, with a transit router | at their own addresses (ranges must not overlap) |

The examples declare the three planes of the reference scenario, keyed by role: `publication`, `observability` and `internal`. In `operator.tfvars.example`, the operator's networks are named `svc_public`, `monitoring` and `intranet`: these are values, replace them with the names of your networks. `shared/planes` takes any number of planes, and the two kinds can be mixed. Two more kinds come in `v0.7`: operator planes routed in a shared address scope (no address translation), with [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-cloud-baseline) ([ADR-0004](../../docs/adr/0004-planes-and-isolation.md), D1), and segments of the operator ([spec](../../docs/specs/operator-segments.md)).

The two can be mixed plane by plane. Order and checkpoints: [getting started](../../docs/getting-started/README.md).
