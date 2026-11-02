# Tenant type `vm`

Two web instances serving several domains, published on the `svc_public` plane and reachable only from the public entry point ([ADR-0001](../../../docs/adr/0001-reference-architecture.md), D5 and D7):

- two VMs in a server group (anti-affinity), each with a floating IP on `svc_public`;
- HTTPS admitted only from the addresses of the entry point on `svc_public`, read from its router by name (`<site>-edge-svc-public`): the stack of the entry point must be applied first;
- routers to the egress network (default route), `svc_public` and `monitoring`, with plane routes pushed by DHCP;
- each instance exposed to the monitoring collector through a floating IP of the monitoring plane, with an A record in the monitoring zone; node exporter (9100) open to the collector's addresses only (`monitoring`);
- an optional bastion for administration.

The web server is a demonstration backend: nginx terminates TLS with a self-signed certificate, accepts the PROXY protocol v2 header from the entry point only, and answers with the host, the server name and the client address it received.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

The stack uses the `cloud` entry of `clouds.yaml` given in `terraform.tfvars`. Make sure no `OS_*` variable is set in the shell.

## Publishing the domains on the entry point

The `published_domains` output has the shape of the `domains` input of the entry point. [`scripts/publish-domains.sh`](../../../scripts/publish-domains.sh) gathers it from every tenant and rolls the entry point instances one at a time; by hand:

```bash
tofu output -json published_domains \
  | jq '{domains: .}' > ../../shared/entry-point/domains.auto.tfvars.json   # git-ignored
```

No address is written by hand (ADR-0001, D9).

## Requirements

- **MTU.** Set `network_mtu` to the smallest of the tenant overlay MTU and the plane MTUs (planes contract). A larger value lets TCP connections open but drops large packets: the TLS handshake then hangs.
- **Range.** `web_cidr` must avoid the ranges reserved by the cloud (planes contract).
- **Internet access at first boot.** The egress network must route to the Internet and the resolvers must be reachable through it (package installation).

## Bastion

With `bastion` set, the stack creates a small network whose only router joins the administration network, and a bastion with a floating IP on it and a second port on the web network. SSH to the web instances is admitted from the bastion only. The second interface ignores the routes and resolvers pushed by DHCP, so the bastion keeps a single default route.

```bash
ssh -J ops@<bastion floating IP> ops@<web instance address>
```

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
| planes | ../../../modules/plane-attachment | n/a |
| web | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | 84c898b5d5036296a7cd3496a54e0721ccbc4936 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| az | Availability zone of the instances. | `string` | n/a | yes |
| cloud | Entry of clouds.yaml used by this stack. | `string` | n/a | yes |
| edge\_sources | Ranges the entry point connects from on svc\_public, in CIDR notation: output<br/>svc\_public\_sources of stack shared/entry-point. Only they may reach the published port and<br/>send a PROXY protocol header. | `list(string)` | n/a | yes |
| egress\_network | External network giving the default route (package installation). The instances get no public address on it. | <pre>object({<br/>    network = string<br/>    subnet  = string<br/>  })</pre> | n/a | yes |
| flavor | Flavor name of the web instances. | `string` | n/a | yes |
| image | Image name of the web instances (an Ubuntu LTS cloud image). | `string` | n/a | yes |
| plane\_attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),<br/>keyed by plane: how its router joins each plane and how its instances are seen there,<br/>whatever provides the plane (the operator, or a hub project). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| site | Short site name; must match the site of the entry point (stack shared/entry-point). | `string` | n/a | yes |
| admin | Administration access: users (login => SSH public keys, sudo granted) and SSH source ranges. No access by default. | <pre>object({<br/>    users     = optional(map(list(string)), {})<br/>    ssh_cidrs = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| bastion | Optional administration bastion. It lives in its own small network whose router joins<br/>external\_network (an administration network such as an intranet) and carries a floating<br/>IP on it. A second port on the web network gives it access to the web instances; the web<br/>network itself gets no route to the administration network.<br/>- ssh\_cidrs: sources allowed to reach the bastion on port 22.<br/>The users of var.admin are created on the bastion and on the web instances. | <pre>object({<br/>    external_network = object({ network = string, subnet = string })<br/>    cidr             = optional(string)<br/>    flavor           = optional(string)<br/>    ssh_cidrs        = list(string)<br/>  })</pre> | `null` | no |
| boot\_volume\_size | Size in GiB of a root volume created from the image; null boots from the flavor's local disk. | `number` | `null` | no |
| dns\_nameservers | DNS resolvers of the web network, reachable through its routes. | `list(string)` | `[]` | no |
| domains | Domains served by the web instances and published through the entry point. | `list(string)` | <pre>[<br/>  "site-a.example.org",<br/>  "site-b.example.org"<br/>]</pre> | no |
| monitoring | Exposure of the instances to the monitoring collector. On a plane with NAT, every instance<br/>gets a floating IP of the monitoring plane; on an interface plane, it is reached at its own<br/>address.<br/>- dns\_zone: zone shared with the project (name with its trailing dot) where an A record per<br/>  instance is written for the collector's DNS service discovery; null writes no record.<br/>- metrics\_ports: ports opened to the collector (node exporter by default).<br/>- collector\_cidrs: addresses of the collector as seen by the instances. null opens the<br/>  metrics ports to the whole monitoring plane range, which includes the routers of every<br/>  tenant joining that plane: set it to keep tenants from scraping each other. | <pre>object({<br/>    dns_zone        = optional(string)<br/>    metrics_ports   = optional(list(number), [9100])<br/>    collector_cidrs = optional(list(string))<br/>  })</pre> | `{}` | no |
| network\_mtu | MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes they join (planes contract): a larger value creates a<br/>path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator<br/>enables it. null keeps the cloud default. | `number` | `null` | no |
| server\_group\_policy | Placement of the two web instances: "anti-affinity" or "soft-anti-affinity". | `string` | `"anti-affinity"` | no |
| web\_cidr | Range of the web network. On planes with NAT tenants may reuse the same range; on interface planes it must be unique (stack shared/planes checks it). | `string` | `"10.21.0.0/24"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| backends | Published backends ("address:443"): floating IPs on svc\_public in gateway mode, the instances' own addresses in interface mode. Published through the entry point (output published\_domains). |
| bastion | Floating IP of the bastion on the administration network, or null. |
| edge\_sources | Addresses of the entry point admitted on port 443. |
| instances | Web instances and their private addresses. |
| monitoring\_targets | Instances exposed to the monitoring collector: floating IP on the monitoring plane and DNS name (or null). |
| published\_domains | Domains served by this tenant and their backends, for the domains input of the entry point (scripts/publish-domains.sh). |
<!-- END_TF_DOCS -->
