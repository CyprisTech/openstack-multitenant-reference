# Shared public entry point

One entry point for every public domain of the site ([ADR-0001](../../../docs/adr/0001-reference-architecture.md), D3 and D8):

- an Octavia load balancer with a public floating IP; listeners in **TCP** on 80 and 443, pools in **PROXY** protocol, **TCP** health monitors;
- two Traefik instances on plain VMs, in a server group (anti-affinity), Traefik running as a Podman container started by systemd;
- routes by **SNI with TLS passthrough**, generated from the `domains` variable; PROXY protocol v2 to the backends that accept it;
- routers to the `svc_public` and `monitoring` planes, with their routes pushed by DHCP;
- each Traefik instance exposed to the monitoring collector through a floating IP of the monitoring plane, with an A record in the monitoring zone; node exporter (9100) and Traefik metrics (8082) open to the collector's addresses only (`monitoring`).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

The stack uses the `cloud` entry of `clouds.yaml` given in `terraform.tfvars`. Make sure no `OS_*` variable is set in the shell: the client would mix it with the `clouds.yaml` entry.

The instances need Internet access at first boot (package index, Podman, Traefik image): `public_network` must provide a default route to the Internet, and `dns_nameservers` must be reachable through it. A resolver that is only reachable on a plane the edge does not join (an intranet resolver, for example) makes the first boot fail and the members stay in `ERROR`.

## Changing the published domains

The routing of Traefik is written by cloud-init, and the module ignores `user_data` changes on existing instances. A change of `domains` takes effect when the instances are replaced, **one at a time**, so that the load balancer keeps one healthy member. [`scripts/publish-domains.sh`](../../../scripts/publish-domains.sh) does it from the tenants' `published_domains` outputs; by hand:

```bash
tofu apply -replace='module.edge.module.instance["SITE-edge-1"].openstack_compute_instance_v2.this'
# wait until the member is ONLINE again: openstack loadbalancer member list SITE-edge-https
tofu apply -replace='module.edge.module.instance["SITE-edge-2"].openstack_compute_instance_v2.this'
```

Connections open on the replaced instance are cut.

## Backends

- `domains.<domain>.backends` take `host:port`. Names must resolve with the `dns_nameservers` of the edge network.
- Backends admit the ranges of the `svc_public_sources` output on their published ports (the tenants' `edge_sources` input). With `proxy_protocol = true` (default), they must expect a PROXY protocol v2 header, from those addresses only.
- Backends terminate TLS and manage their certificates: use DNS-01 or TLS-ALPN-01 challenges ([trade-offs](../../../docs/concepts/trade-offs.md#1-tls-passthrough-at-the-public-entry-point)).

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
| admission | ../../../modules/admission | n/a |
| bastion | ../../../modules/bastion | n/a |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.3 |
| edge | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | 84c898b5d5036296a7cd3496a54e0721ccbc4936 |
| planes | ../../../modules/plane-attachment | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [openstack_networking_router_v2.svc_public](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_router_v2) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| az | Availability zone of the instances. | `string` | n/a | yes |
| cloud | Entry of clouds.yaml used by this stack. | `string` | n/a | yes |
| flavor | Flavor name of the edge instances. | `string` | n/a | yes |
| image | Image name of the edge instances (an Ubuntu LTS cloud image). | `string` | n/a | yes |
| plane\_attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),<br/>keyed by plane: how its router joins each plane and how its instances are seen there,<br/>whatever provides the plane (the operator, or a hub project). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| public\_network | External network providing the public floating IP of the load balancer and the default route of the edge network. | <pre>object({<br/>    network = string<br/>    subnet  = string<br/>  })</pre> | n/a | yes |
| site | Short site name, used in resource names (ADR-0001, D9). | `string` | n/a | yes |
| admin | Administration access to the Traefik instances. users: login => SSH public keys (sudo granted).<br/>ssh\_cidrs: sources allowed on port 22. Empty by default: no SSH access. | <pre>object({<br/>    users     = optional(map(list(string)), {})<br/>    ssh_cidrs = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| bastion | Optional administration bastion. It lives in its own small network whose router joins<br/>external\_network (an administration network such as an intranet) and carries a floating<br/>IP on it. A second port on the edge network gives it access to the Traefik instances; the edge<br/>network itself gets no route to the administration network.<br/>- ssh\_cidrs: sources allowed to reach the bastion on port 22.<br/>The users of var.admin are created on the bastion and on the Traefik instances. | <pre>object({<br/>    external_network = object({ network = string, subnet = string })<br/>    cidr             = optional(string)<br/>    flavor           = optional(string)<br/>    ssh_cidrs        = list(string)<br/>  })</pre> | `null` | no |
| boot\_volume\_size | Size in GiB of a root volume created from the image; null boots from the flavor's local disk. | `number` | `null` | no |
| dns\_nameservers | DNS resolvers pushed by DHCP on the edge network. They must be reachable through the edge routes (public network or a plane), and resolve the backend names used in routes. Without them, the first boot cannot install Podman nor pull the Traefik image. | `list(string)` | `[]` | no |
| domains | Public domains routed by SNI, keyed by domain name.<br/>- backends: "host:port" of the backends (addresses or names resolvable from the edge network).<br/>- proxy\_protocol: send PROXY protocol v2 to the backends; they must be configured to accept it.<br/>- max\_connections: simultaneous connections allowed per client address.<br/>A change takes effect when the instances are replaced, one at a time: scripts/publish-domains.sh<br/>does it from the published\_domains outputs of the tenants (see README). | <pre>map(object({<br/>    backends        = list(string)<br/>    proxy_protocol  = optional(bool, true)<br/>    max_connections = optional(number, 100)<br/>  }))</pre> | `{}` | no |
| edge\_cidr | Range of the edge network. The load balancer, its amphorae and the Traefik instances live in it. | `string` | `"10.20.0.0/24"` | no |
| monitoring | Exposure of the instances to the monitoring collector. On a plane with NAT, every instance<br/>gets a floating IP of the monitoring plane; on an interface plane, it is reached at its own<br/>address.<br/>- dns\_zone: zone shared with the project (name with its trailing dot) where an A record per<br/>  instance is written for the collector's DNS service discovery; null writes no record.<br/>- metrics\_ports: ports opened to the collector (node exporter by default).<br/>- collector\_cidrs: addresses of the collector as seen by the instances. null opens the<br/>  metrics ports to the whole monitoring plane range, which includes the routers of every<br/>  tenant joining that plane: set it to keep tenants from scraping each other. | <pre>object({<br/>    dns_zone        = optional(string)<br/>    metrics_ports   = optional(list(number), [9100])<br/>    collector_cidrs = optional(list(string))<br/>  })</pre> | `{}` | no |
| network\_mtu | MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes they join (planes contract): a larger value creates a<br/>path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator<br/>enables it. null keeps the cloud default. | `number` | `null` | no |
| octavia\_flavor\_id | Octavia flavor; an active/standby flavor is recommended for the edge. null uses the cloud default. | `string` | `null` | no |
| public\_dns | Optional A records on the public floating IP: an existing zone (name with its trailing dot) and relative names ("" for the apex). | <pre>object({<br/>    zone  = string<br/>    names = list(string)<br/>    ttl   = optional(number, 300)<br/>  })</pre> | `null` | no |
| server\_group\_policy | Placement of the two Traefik instances: "anti-affinity" (two hosts required) or "soft-anti-affinity". | `string` | `"anti-affinity"` | no |
| traefik\_image | Fully qualified, pinned Traefik image. | `string` | `"docker.io/library/traefik:v3.7.16"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bastion | Floating IP of the bastion on the administration network, or null. |
| domains | Domains currently routed by the entry point. |
| instances | Traefik instances and their addresses on the edge network. |
| load\_balancer | Virtual IP, public floating IP and DNS names of the entry point. |
| monitoring\_targets | Instances exposed to the monitoring collector: floating IP on the monitoring plane and DNS name (or null). |
| svc\_public\_sources | Ranges the edge connects from on svc\_public, in CIDR notation: the router's gateway address in gateway mode, the edge range in interface mode. Backends admit them on their published ports (ADR-0001, D7); pass them to the tenant stacks (edge\_sources). |
<!-- END_TF_DOCS -->
