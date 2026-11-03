# Module `bastion`

An optional administration bastion, written once for every stack ([ADR-0001](../../docs/adr/0001-reference-architecture.md), D10). It creates nothing itself: its outputs are fragments of the tenant model of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant), all empty when `bastion` is null.

The bastion has its own small network, whose only router joins an administration network and carries the bastion's floating IP; a second port on the stack's network reaches the stack's instances. The stack's network gets no route to the administration network.

| Output | Use in the stack |
|---|---|
| `existing_networks` | merged into `tenant.existing.networks` (key `admin`) |
| `networks` | merged into `tenant.networks` |
| `security_groups` | merged into `tenant.security_groups`: SSH from `bastion.ssh_cidrs` |
| `instances` | merged into `tenant.instances` |
| `ssh_rules` | merged into the rules of the instances' security group: SSH from the bastion |

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.4 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_network | Name of the bastion's own network (and key in tenant.networks). | `string` | n/a | yes |
| bastion | The bastion, or null for none. It lives in its own small network whose router joins<br/>external\_network (an administration network such as an intranet) and carries a floating IP<br/>on it; a second port on the stack's network gives it access to the stack's instances.<br/>- ssh\_cidrs: sources allowed to reach the bastion on port 22. | <pre>object({<br/>    external_network = object({ network = string, subnet = string })<br/>    cidr             = optional(string)<br/>    flavor           = optional(string)<br/>    ssh_cidrs        = list(string)<br/>  })</pre> | n/a | yes |
| default\_cidr | Range of the bastion's network when bastion.cidr is not set. | `string` | n/a | yes |
| instance | Placement and image of the bastion, as for the stack's instances. | <pre>object({<br/>    az     = string<br/>    image  = string<br/>    flavor = string<br/>    boot   = any<br/>  })</pre> | n/a | yes |
| name | Name of the bastion instance; its network, router and security group are named after it. | `string` | n/a | yes |
| network | Key of the stack's network (subnet main) where the bastion gets its second port. | `string` | n/a | yes |
| dns\_nameservers | Resolvers of the bastion's network. | `list(string)` | `[]` | no |
| mtu | MTU of the bastion's network. | `number` | `null` | no |
| port | Key of the bastion's second port, on the stack's network. | `string` | `"main"` | no |
| users | Administrators created on the bastion: login => SSH public keys (sudo granted). | `map(list(string))` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| existing\_networks | For tenant.existing.networks: the administration network, under the key admin. |
| instances | For tenant.instances: the bastion, with its floating IP on the administration network. |
| networks | For tenant.networks: the bastion's network, whose only router joins the administration network. |
| security\_groups | For tenant.security\_groups: the bastion's group, SSH from bastion.ssh\_cidrs. |
| ssh\_rules | Rules to add to the security group of the stack's instances: SSH from the bastion. |
<!-- END_TF_DOCS -->
