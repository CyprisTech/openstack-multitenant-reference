# Test resolver

A small instance standing for a **resolver behind a plane** ([ADR-0016](../../../docs/adr/0016-network-services-and-edge-by-level.md), D3), a shared service of the internal services plane: the operator's resolvers on an operator plane, the organisation's DNS, or a platform team's service. A tenant without egress, such as the private tenant, joins the plane and takes the `resolver` output as its `dns_nameservers`.

- **Unbound** answers the tenants of the plane on port 53 (UDP and TCP): the zones of the landing zone are forwarded to their servers (`forward_zones`), other names are resolved recursively through `egress_network`.
- On an operator plane (with address translation), its address on the plane is a floating IP of the plane, and it admits queries from the whole plane range; on a hub plane, its own address, and it admits the tenant ranges routed to it.

The reference runs no resolver: this fixture is for the tests only, like [`receiver`](../receiver/README.md). It gets its packages through `egress_network` and is administered through a bastion, like the stacks. Create it after `stacks/shared/planes` and before the tenants that use it.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; zones = ["..."]; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
egress_network = { network = "public", subnet = "public-subnet" }
bastion        = { external_network = { network = "intranet", subnet = "intranet" }, ssh_cidrs = ["192.0.2.10/32"] }
users          = { ops = ["ssh-ed25519 AAAA..."] }
forward_zones  = { "example.org" = ["192.0.2.53"] }
VARS
tofu -chdir=../../../stacks/shared/planes output -json attachments | jq '{plane_attachment: .resolver.planes}' > planes.auto.tfvars.json
tofu init && tofu apply
tofu output -raw resolver
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
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.6 |
| planes | ../../../modules/plane-attachment | n/a |
| resolver | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | v0.1.6 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bastion | Administration bastion: floating IP on external\_network, SSH from ssh\_cidrs. Where it lives: var.bastion\_placement. | <pre>object({<br/>    external_network = object({<br/>      network = string<br/>      subnet  = optional(string)<br/>    })<br/>    ssh_cidrs = list(string)<br/>  })</pre> | n/a | yes |
| cloud | n/a | `string` | n/a | yes |
| egress\_network | External network giving the default route: packages, and the recursion for public names. subnet: optional, the subnet of that network to look up by name; without it, Neutron chooses (a public network with several subnets of the same name). | <pre>object({<br/>    network = string<br/>    subnet  = optional(string)<br/>  })</pre> | n/a | yes |
| flavor | n/a | `string` | n/a | yes |
| image | n/a | `string` | n/a | yes |
| plane\_attachment | The service's entry of the attachments output of stack shared/planes (role shared on internal). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes = optional(list(object({<br/>      destination = string<br/>      next_hop    = string<br/>    })), [])<br/>  }))</pre> | n/a | yes |
| site | n/a | `string` | n/a | yes |
| users | SSH users (login => public keys, sudo granted), on the bastion and the resolver. | `map(list(string))` | n/a | yes |
| zones | Availability zones; the fixture runs in the first one, as the single instances of the stacks. | `list(string)` | n/a | yes |
| bastion\_placement | Where the bastion lives (ADR-0014, D2): "own-network" (default), its own small network whose<br/>router joins bastion.external\_network; or "stack-network", one port on the stack's network<br/>and its floating IP on the egress router, when bastion.external\_network is the egress\_network.<br/>A choice of the profile: private-cloud keeps "own-network", public-cloud takes "stack-network". | `string` | `"own-network"` | no |
| boot\_volume\_size | n/a | `number` | `null` | no |
| cidr | Range of the resolver's network; on a hub plane, the attachment's cidr in shared/planes. | `string` | `"10.38.0.0/28"` | no |
| dns\_nameservers | n/a | `list(string)` | `[]` | no |
| forward\_zones | Zones of the landing zone the resolver forwards to their servers (zone => server addresses), such as the test zone served by the organisation's DNS. Other names are resolved recursively through egress\_network. | `map(list(string))` | `{}` | no |
| network\_mtu | n/a | `number` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| address | Address of the resolver on its network, reached through the bastion (SSH). |
| bastion | Floating IP of the bastion on the administration network. |
| resolver | Address of the resolver on the internal services plane (port 53), for the dns\_nameservers input of a tenant that joins the plane. |
| sources | Sources admitted on port 53. |
<!-- END_TF_DOCS -->
