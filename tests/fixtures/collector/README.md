# Test collector

A small instance standing for the monitoring collector, a **shared service of the monitoring plane**, used by the [isolation test](../../isolation/README.md). The tenants admit it by the addresses of its `collector_cidrs` output, given to every tenant stack as `monitoring.collector_cidrs`:

- on an operator plane (gateway mode), its router reaches the plane with source NAT: one known address, the router's gateway address;
- on an interface plane (`shared/planes`, role `shared` on `monitoring`), no translation: the collector's own range (`cidr`), routed to every tenant through the transit router.

It is administered through a floating IP on an administration network, whose router is its default gateway. Create it **before** the tenant stacks, which need `collector_cidrs`.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
admin_network = { network = "intranet", subnet = "intranet" }
ssh_cidrs     = ["192.0.2.0/24"]
ssh_keys      = ["ssh-ed25519 AAAA..."]
VARS
tofu -chdir=../../../stacks/shared/planes output -json attachments | jq '{plane_attachment: ."collector".planes}' > planes.auto.tfvars.json
tofu init && tofu apply
tofu output -json collector_cidrs
```

Like any shared service, it runs in its own project, not in the hub project (which holds the network only).

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| openstack | ~> 3.2 |

### Providers

| Name | Version |
| ---- | ------- |
| openstack | ~> 3.2 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.3 |
| collector | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | 84c898b5d5036296a7cd3496a54e0721ccbc4936 |
| planes | ../../../modules/plane-attachment | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [openstack_networking_router_v2.monitoring](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_router_v2) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_network | n/a | `object({ network = string, subnet = string })` | n/a | yes |
| az | n/a | `string` | n/a | yes |
| cloud | n/a | `string` | n/a | yes |
| flavor | n/a | `string` | n/a | yes |
| image | n/a | `string` | n/a | yes |
| plane\_attachment | The service's entry of the attachments output of stack shared/planes (role shared on monitoring). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| site | n/a | `string` | n/a | yes |
| ssh\_cidrs | n/a | `list(string)` | n/a | yes |
| ssh\_keys | n/a | `list(string)` | n/a | yes |
| boot\_volume\_size | n/a | `number` | `null` | no |
| cidr | Range of the collector's network; on an interface plane, the attachment's cidr in shared/planes. | `string` | `"10.34.0.0/28"` | no |
| network\_mtu | n/a | `number` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| address | Floating IP of the collector on the administration network (SSH). |
| collector\_cidrs | Source addresses of the collector as seen by the tenants: its router's gateway address on an operator plane, its range on an interface plane. |
<!-- END_TF_DOCS -->
