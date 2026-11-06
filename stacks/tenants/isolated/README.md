# Tenant type `isolated`

A workload with no public exposure and no path to the other tenants ([ADR-0003](../../../docs/adr/0003-scope-and-boundary.md), D3):

- one network whose **only router** joins the observability plane, its default gateway;
- no egress network, no route to the publication plane or to the Internet;
- the workload pushes its metrics to your receiver through the observability plane (`monitoring.receiver`); nothing connects into the tenant;
- an optional bastion for administration.

The workload is a stand-in with no package and no Internet access: a Python standard-library service that pushes one metric (`isolated_up`) in OTLP, JSON over HTTP, which the receiver accepts next to remote write.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

## Why the tenant reaches the receiver only

Its router is its only way out, and the only ranges routed through it are the observability plane's and the shared services routed on that plane: the receiver. Every flow is outbound; the security group of the instance admits SSH from its bastion only.

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
| isolated | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | v0.1.4 |
| planes | ../../../modules/plane-attachment | n/a |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| az | Availability zone of the instances. | `string` | n/a | yes |
| cloud | Entry of clouds.yaml used by this stack. | `string` | n/a | yes |
| flavor | Flavor name of the instance. | `string` | n/a | yes |
| image | Image name of the instance (an Ubuntu LTS cloud image). | `string` | n/a | yes |
| plane\_attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),<br/>keyed by plane: how its router joins each plane and how its instances are seen there,<br/>whatever provides the plane (the operator, or a hub project). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| site | Short site name; must match the site of the entry point (stack shared/entry-point). | `string` | n/a | yes |
| admin | Administration access: users (login => SSH public keys, sudo granted) and SSH source ranges. No access by default. | <pre>object({<br/>    users     = optional(map(list(string)), {})<br/>    ssh_cidrs = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| bastion | Optional administration bastion. It lives in its own small network whose router joins<br/>external\_network (an administration network such as an intranet) and carries a floating<br/>IP on it. A second port on the isolated network gives it access to the instance; the isolated<br/>network itself gets no route to the administration network.<br/>- ssh\_cidrs: sources allowed to reach the bastion on port 22.<br/>The users of var.admin are created on the bastion and on the isolated instance. | <pre>object({<br/>    external_network = object({ network = string, subnet = string })<br/>    cidr             = optional(string)<br/>    flavor           = optional(string)<br/>    ssh_cidrs        = list(string)<br/>  })</pre> | `null` | no |
| boot\_volume\_size | Size in GiB of a root volume created from the image; null boots from the flavor's local disk. | `number` | `null` | no |
| dns\_nameservers | DNS resolvers of the tenant network, reachable through its routes. | `list(string)` | `[]` | no |
| isolated\_cidr | Range of the isolated network. On planes with NAT it may overlap the ranges of other tenants; on a plane without NAT it must not (shared/planes checks it). | `string` | `"10.22.0.0/24"` | no |
| monitoring | Monitoring as a push integration point (ADR-0007): the workload pushes its metrics to the<br/>receiver through the observability plane, its only way out. Nothing connects into the tenant.<br/>- receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output<br/>  receiver\_url of the receiver); null pushes nothing. | <pre>object({<br/>    receiver = optional(string)<br/>  })</pre> | `{}` | no |
| network\_mtu | MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes they join (planes contract): a larger value creates a<br/>path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator<br/>enables it. null keeps the cloud default. | `number` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bastion | Floating IP of the bastion on the administration network, or null. |
| instances | Isolated instance and its private address. |
<!-- END_TF_DOCS -->
