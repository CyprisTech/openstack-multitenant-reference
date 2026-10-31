# Module `plane-attachment`

How a stack joins the shared planes, from the descriptor `shared/planes` outputs for it (a router gateway or interface per plane, floating IPs or own addresses) ([ADR-0003](../../docs/adr/0003-scope-and-plane-provisioning.md), D2; [How a tenant joins a plane](../../docs/concepts/plane-attachment.md)), written once for every stack. It creates nothing: its outputs are fragments of the tenant model of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant).

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
