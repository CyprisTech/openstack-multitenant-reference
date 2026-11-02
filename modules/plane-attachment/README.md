# Module `plane-attachment`

How a stack joins the shared planes, from the descriptor `shared/planes` outputs for it (a router gateway or interface per plane, floating IPs or own addresses) ([ADR-0004](../../docs/adr/0004-planes-and-isolation.md); [How a tenant joins a plane](../../docs/concepts/plane-attachment.md)), written once for every stack. It creates nothing: its outputs are fragments of the tenant model of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant).

| Output | Use in the stack |
|---|---|
| `networks` | `tenant.existing.networks`: the planes, by ID |
| `routers` | `tenant.networks.<network>.routers`: one router per plane — a gateway in gateway mode; an interface and routes through the transit router in interface mode; the ranges pushed by DHCP in both |
| `ports` | per instance: `floating_ip`, `extra_floating_ips`, `dns` — floating IPs of the planes in gateway mode, the instance's own address in interface mode |
| `mode`, `nat`, `cidr`, `network_name` | per plane, for the stack's own rules and outputs |

```hcl
module "planes" {
  source = "../../../modules/plane-attachment"

  planes          = ["svc_public", "monitoring"]
  attachment      = var.plane_attachment # attachments.<name>.planes, output of shared/planes
  instances       = local.instances
  exposure        = { primary = "svc_public", extra = ["monitoring"], dns = { plane = "monitoring", zone = "monitoring" } }
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
| planes | Planes the stack joins, keyed by name (svc\_public, monitoring, intranet). | `list(string)` | n/a | yes |
| default\_gateway | Plane whose router is the default gateway of the stack's network (a tenant with no other way out), or null. Its range needs no route pushed by DHCP. | `string` | `null` | no |
| exposure | How the instances are reached on the planes. In gateway mode through floating IPs of the<br/>plane, in interface mode at their own address (nothing to create).<br/>- primary: plane of the port's primary floating IP (published backends), or null.<br/>- extra: planes of additional floating IPs (monitoring targets).<br/>- dns: A record per instance, named after it, in zone (key of the stack's DNS zones),<br/>  for the address on plane: the floating IP in gateway mode, the fixed IP in interface mode. | <pre>object({<br/>    primary = optional(string)<br/>    extra   = optional(list(string), [])<br/>    dns     = optional(object({ plane = string, zone = string }))<br/>  })</pre> | `{}` | no |
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
| ports | Exposure of each instance's port, keyed by instance: floating\_ip, extra\_floating\_ips and dns attributes of the tenant model. |
| routers | One router per plane, keyed by the plane name with dashes (svc-public, monitoring), for tenant.networks.<network>.routers. |
<!-- END_TF_DOCS -->
