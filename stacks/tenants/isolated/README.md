# Tenant type `isolated`

A workload with no public exposure and no path to the other tenants ([ADR-0001](../../../docs/adr/0001-reference-architecture.md), D5):

- one network whose **only router** joins the monitoring plane: it carries the instance's floating IP on that plane and the replies to the collector;
- no egress network, no route to `svc_public` or to the Internet;
- metrics open to the collector only (`monitoring.collector_cidrs`), with an A record in the monitoring zone for DNS service discovery;
- an optional bastion for administration.

The workload is a stand-in: a metrics endpoint served by the Python standard library, so that the instance needs no package and no Internet access.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

## Why the metrics are open to the collector only

Every tenant that joins the monitoring plane does so through a router with source NAT: seen from the plane, all tenants have addresses in the plane range. Opening the metrics ports to the whole range would let any tenant scrape any other. `monitoring.collector_cidrs` restricts them to the collector's addresses; with `null`, the whole plane range is admitted.

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
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.3 |
| isolated | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | 84c898b5d5036296a7cd3496a54e0721ccbc4936 |
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
| dns\_nameservers | DNS resolvers of the web network, reachable through its routes. | `list(string)` | `[]` | no |
| isolated\_cidr | Range of the isolated network. With operator planes it may overlap the ranges of other tenants; on an interface plane it must not (shared/planes checks it). | `string` | `"10.22.0.0/24"` | no |
| monitoring | Exposure of the instance to the monitoring collector (ADR-0001, D2): a floating IP of the<br/>monitoring plane in gateway mode, its own address in interface mode.<br/>- dns\_zone: zone shared with the project (name with its trailing dot) where an A record per<br/>  instance is written for the collector's DNS service discovery; null writes no record.<br/>- metrics\_ports: ports opened to the collector (node exporter by default).<br/>- collector\_cidrs: addresses of the collector as seen by the instances. null opens the<br/>  metrics ports to the whole monitoring plane range, which includes the routers of every<br/>  tenant joining that plane: set it to keep tenants from scraping each other. | <pre>object({<br/>    dns_zone        = optional(string)<br/>    metrics_ports   = optional(list(number), [9100])<br/>    collector_cidrs = optional(list(string))<br/>  })</pre> | `{}` | no |
| network\_mtu | MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes they join (planes contract): a larger value creates a<br/>path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator<br/>enables it. null keeps the cloud default. | `number` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bastion | Floating IP of the bastion on the administration network, or null. |
| instances | Isolated instance and its private address. |
| monitoring\_targets | Instance exposed to the monitoring collector: its address on the monitoring plane (floating IP in gateway mode, own address in interface mode) and DNS name (or null). |
<!-- END_TF_DOCS -->
