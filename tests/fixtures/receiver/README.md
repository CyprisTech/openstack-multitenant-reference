# Test receiver

A small instance standing for your metrics receiver, a **shared service of the observability plane** ([ADR-0007](../../../docs/adr/0007-monitoring.md)), used by the tests and the [isolation test](../../isolation/README.md). It runs Prometheus with its remote-write and OTLP receivers; every stack pushes to its `receiver_url` output, given as `monitoring.receiver`. Nothing connects into the tenants.

- On an operator plane (with address translation), its address on the plane is a floating IP of the observability plane, and it admits pushes from the whole plane range: the tenants arrive from their routers' gateway addresses.
- On a hub plane (`shared/planes`, role `shared` on `observability`), its own address, and it admits the tenant ranges routed to it through the transit router.

It gets its packages and its image through `egress_network`, and is administered through a bastion, like the stacks. Create it **before** the tenant stacks, which need `receiver_url`.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
egress_network = { network = "public", subnet = "public-subnet" }
bastion        = { external_network = { network = "intranet", subnet = "intranet" }, ssh_cidrs = ["192.0.2.10/32"] }
users          = { ops = ["ssh-ed25519 AAAA..."] }
VARS
tofu -chdir=../../../stacks/shared/planes output -json attachments | jq '{plane_attachment: .receiver.planes}' > planes.auto.tfvars.json
tofu init && tofu apply
tofu output -raw receiver_url
```

Like any shared service, it runs in its own project, not in the hub project (which holds the network only).

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| openstack | ~> 3.2 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| admission | ../../../modules/admission | n/a |
| bastion | ../../../modules/bastion | n/a |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.4 |
| planes | ../../../modules/plane-attachment | n/a |
| receiver | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | v0.1.4 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| az | n/a | `string` | n/a | yes |
| bastion | Administration bastion: floating IP on external\_network, SSH from ssh\_cidrs. | <pre>object({<br/>    external_network = object({ network = string, subnet = string })<br/>    ssh_cidrs        = list(string)<br/>  })</pre> | n/a | yes |
| cloud | n/a | `string` | n/a | yes |
| egress\_network | External network giving the default route (package and image download). | `object({ network = string, subnet = string })` | n/a | yes |
| flavor | n/a | `string` | n/a | yes |
| image | n/a | `string` | n/a | yes |
| plane\_attachment | The service's entry of the attachments output of stack shared/planes (role shared on observability). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| site | n/a | `string` | n/a | yes |
| users | SSH users (login => public keys, sudo granted), on the bastion and the receiver. | `map(list(string))` | n/a | yes |
| boot\_volume\_size | n/a | `number` | `null` | no |
| cidr | Range of the receiver's network; on a hub plane, the attachment's cidr in shared/planes. | `string` | `"10.34.0.0/28"` | no |
| dns\_nameservers | n/a | `list(string)` | `[]` | no |
| network\_mtu | n/a | `number` | `null` | no |
| prometheus\_image | Prometheus image, pinned. | `string` | `"docker.io/prom/prometheus:v3.15.1"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| address | Address of the receiver on its network, reached through the bastion (SSH). |
| bastion | Floating IP of the bastion on the administration network. |
| receiver\_url | Base URL of the receiver, for the monitoring.receiver input of the stacks. |
<!-- END_TF_DOCS -->
