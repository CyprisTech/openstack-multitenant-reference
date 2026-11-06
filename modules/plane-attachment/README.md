# Module `plane-attachment`

How a stack joins the shared planes, from the descriptor `shared/planes` outputs for it (a router gateway or interface per plane, floating IPs or own addresses) ([ADR-0004](../../docs/adr/0004-planes-and-isolation.md); [How a tenant joins a plane](../../docs/concepts/plane-attachment.md)), written once for every stack. It creates nothing: its outputs are fragments of the tenant model of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant).

| Output | Use in the stack |
|---|---|
| `networks` | `tenant.existing.networks`: the planes, by ID |
| `routers` | `tenant.networks.<network>.routers`: one router per plane — a gateway in gateway mode; an interface and routes through the transit router in interface mode; the ranges pushed by DHCP in both |
| `ports` | per instance: `floating_ip` — a floating IP of the primary plane when it translates addresses, none otherwise (at most one floating IP per address, [ADR-0006](../../docs/adr/0006-exposure.md)) |
| `mode`, `nat`, `cidr`, `network_name` | per plane, for the stack's own rules and outputs |

```hcl
module "planes" {
  source = "../../../modules/plane-attachment"

  planes          = ["publication", "observability"]
  attachment      = var.plane_attachment # attachments.<name>.planes, output of shared/planes
  instances       = local.instances
  exposure        = { primary = "publication" } # a single instance as the service address
}
```

The other building blocks: [`bastion`](../bastion/README.md), [`admission`](../admission/README.md); for `stacks/shared/planes`, [`plane-discovery`](../plane-discovery/README.md) and [`range-overlaps`](../range-overlaps/README.md).

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes), keyed by plane: one descriptor per plane, whatever provides it. | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| planes | Planes the stack joins, keyed by name (publication, observability, internal). | `list(string)` | n/a | yes |
| default\_gateway | Plane whose router is the default gateway of the stack's network (a tenant with no other way out), or null. Its range needs no route pushed by DHCP. | `string` | `null` | no |
| exposure | How the instances are reached on the planes: through a floating IP of the plane when it<br/>translates addresses, at their own address otherwise (nothing to create). At most one<br/>floating IP per address (ADR-0006, D4).<br/>- primary: plane on which each instance is a service address, or null. | <pre>object({<br/>    primary = optional(string)<br/>  })</pre> | `{}` | no |
| instances | Instances whose ports are exposed on the planes (see exposure). | `list(string)` | `[]` | no |
| internal\_subnet | Key of the subnet the plane routers are attached to, in the stack's network. | `string` | `"main"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| cidr | Range of each plane. |
| mode | Mode of each plane: gateway or interface. |
| nat | Per plane: true when the instances are reached through floating IPs of the plane, false at their own addresses. |
| network\_name | Name of each plane's network (a floating IP pool, for nat planes). |
| networks | Planes to adopt, for tenant.existing.networks, by ID. |
| ports | Exposure of each instance's port, keyed by instance: the floating\_ip attribute of the tenant model (a floating IP of the primary plane when it translates addresses, null otherwise). |
| routers | One router per plane, keyed by the plane name (publication, observability), for tenant.networks.<network>.routers. |
<!-- END_TF_DOCS -->
