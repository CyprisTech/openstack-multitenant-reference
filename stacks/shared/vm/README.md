# Shared service on virtual machines

A shared service on virtual machines offers a service to the tenants on the internal services plane, as the [shared cluster](../kubernetes/README.md) does with Kubernetes: a database, a directory, an artifact repository, a license server. The stack brings what the landing zone requires around the service; the workload is yours ([ADR-0003](../../../docs/adr/0003-scope-and-boundary.md), D4), and so is running it (backups, replication, upgrades).

- **In a project of shared services**, attached with the role `shared` on the internal services plane and `tenant` on the observability plane. It does not join the publication plane: a service published on the Internet is a [`vm` tenant](../../tenants/vm/README.md).
- **One address per service** ([ADR-0006](../../../docs/adr/0006-exposure.md), D1), keyed in `services`: an internal load balancer with a TCP listener per port when there are several instances, the instance itself when there is one. A floating IP of the plane when it translates addresses, the address itself otherwise.
- **Closed by default, then admitted to its consumers only** (`consumers`, or the `sources` of a service): on the ports of the services, by the listeners and by the security group of the instances. In the other direction, the output `sources` gives the service's address on the internal services plane, for the admission rules of what it calls. Network admission does not identify a user: authentication belongs to the service.
- **Spread over the zones**, in an anti-affinity server group ([ADR-0012](../../../docs/adr/0012-resilience-scope.md)); the bastion in the first zone.
- **Names**: the `domains` of each service, written in a zone of the internal names when the cloud has Designate, given as `dns_records` otherwise ([ADR-0016](../../../docs/adr/0016-network-services-and-edge-by-level.md), D2).
- **TLS terminated by the service** ([ADR-0008](../../../docs/adr/0008-tenant-certificates.md), D5): the load balancers pass TCP through, so that a consumer checks the service's certificate, HTTP or not. Each instance obtains a certificate for the domains with lego through DNS-01, in `/etc/shared-service/tls/cert.pem` and `key.pem`, and runs `tls_reload` after each issuance and renewal. Without `certificates`, a self-signed certificate for the domains, with a warning at every plan.
- **Egress declared** ([ADR-0016](../../../docs/adr/0016-network-services-and-edge-by-level.md), D1): `router`, `shared` (through the shared egress) or `none` (an image that holds the workload).
- When the service joins the observability plane, each instance runs the metrics agent, which pushes to the receiver there ([ADR-0007](../../../docs/adr/0007-monitoring.md)).

Without `workload`, the stack runs a demonstration: on each port of `services`, an answer with the name of the service and of the instance, over HTTPS when the instance has a certificate, HTTP otherwise. The reference's test scenario deploys it as the internal service its consumers must reach and the other tenants must not.

## Your workload

`workload` adds to the cloud-init of each instance: `packages`, `write_files` and `runcmd`. The stack does not template it: a setting that depends on the instance (its address, its zone) reads the instance metadata (`http://169.254.169.254/openstack/latest/meta_data.json`). Declare the ports it listens on in `services`, and the command that loads a new certificate in `tls_reload`:

```hcl
services = {
  registry = { ports = [443], domains = ["registry.int.example.org"] }
}
workload = {
  packages = ["docker.io"]
  runcmd   = ["docker run -d --restart always -p 443:5000 -v /etc/shared-service/tls:/certs -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/cert.pem -e REGISTRY_HTTP_TLS_KEY=/certs/key.pem registry:2"]
}
tls_reload = "docker restart $(docker ps -q --filter ancestor=registry:2)"
```

A changed workload reaches new instances only: the instances keep the user data they booted with. Replace them one by one (`-replace`), or let your configuration management update them.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt; consumers = the consumers' internal_sources
tofu -chdir=../planes output -json attachments | jq '{plane_attachment: .service.planes}' > planes.auto.tfvars.json
tofu init && tofu apply
tofu output services
```

With [`lz deploy`](../../../tools/landing-zone/README.md), it is a shared service of type `vm`: `lz` gives it its attachment, the receiver and the consumers' addresses.

## Add a consumer

A consumer is a tenant, once it has joined the internal services plane, or a range of users ([how they reach the plane](../../../docs/reference/integration-points.md#users-of-internal-services)). Add its `internal_sources` output, or the users' range, to `consumers`, and apply the stack. The listeners and the security group then admit it; the addresses do not change.

The consumers need the names (written in `internal_zone`, or published with your DNS provider from `dns_records`) and, when the authority is not publicly trusted, its root: the `ca_bundle` of `certificates` ([shared cluster](../kubernetes/README.md#names-and-root-certificate-for-the-consumers)).

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
| acme | ../../../modules/acme-client | n/a |
| admission | ../../../modules/admission | n/a |
| bastion | ../../../modules/bastion | n/a |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.6 |
| metrics | ../../../modules/metrics-agent | n/a |
| names | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/dns | v0.1.6 |
| planes | ../../../modules/plane-attachment | n/a |
| service | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | v0.1.6 |

### Resources

| Name | Type |
| ---- | ---- |
| [openstack_networking_router_v2.internal](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_router_v2) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cloud | Entry of clouds.yaml used by this stack. | `string` | n/a | yes |
| egress | How the service reaches the Internet (ADR-0016, D1), for its packages, the ACME directory and<br/>the metrics agent:<br/>- "router": its own router to egress\_network, which takes the default route;<br/>- "shared": the shared egress of the landing zone (stack shared/egress), through the proxy of<br/>  shared\_egress, for the names the service is declared with there;<br/>- "none": no default route, no package: an image that holds the workload already, and an ACME<br/>  directory and a receiver reached through the planes.<br/>Required: what a shared service reaches is declared. | `string` | n/a | yes |
| flavor | Flavor name of the instances. | `string` | n/a | yes |
| image | Image name of the instances (an Ubuntu LTS cloud image). | `string` | n/a | yes |
| plane\_attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),<br/>keyed by plane: how its router joins each plane and how its instances are seen there,<br/>whatever provides the plane (the operator, or a hub project). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes = optional(list(object({<br/>      destination = string<br/>      next_hop    = string<br/>    })), [])<br/>  }))</pre> | n/a | yes |
| site | Short site name; must match the site of the entry point (stack shared/entry-point). | `string` | n/a | yes |
| zones | Availability zones of the instances, at least one. The instances of a role are spread over them in order (the first instance in the first zone); changing the order moves instances. One zone places everything in it. | `list(string)` | n/a | yes |
| admin | Administration access: users (login => SSH public keys, sudo granted) and SSH source ranges. No access by default. | <pre>object({<br/>    users     = optional(map(list(string)), {})<br/>    ssh_cidrs = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| bastion | Optional administration bastion. By default it lives in its own small network whose router joins<br/>external\_network (an administration network such as an intranet) and carries a floating<br/>IP on it. A second port on the service's network gives it access to the instances; the<br/>network itself gets no route to the administration network.<br/>var.bastion\_placement may put it on the stack's network instead (ADR-0014, D2).<br/>- ssh\_cidrs: sources allowed to reach the bastion on port 22.<br/>The users of var.admin are created on the bastion and on the instances. | <pre>object({<br/>    external_network = object({<br/>      network = string<br/>      subnet  = optional(string)<br/>    })<br/>    cidr      = optional(string)<br/>    flavor    = optional(string)<br/>    ssh_cidrs = list(string)<br/>  })</pre> | `null` | no |
| bastion\_placement | Where the bastion lives (ADR-0014, D2): "own-network" (default), its own small network whose<br/>router joins bastion.external\_network; or "stack-network", one port on the stack's network<br/>and its floating IP on the egress router, when bastion.external\_network is the egress\_network.<br/>A choice of the profile: private-cloud keeps "own-network", public-cloud takes "stack-network". | `string` | `"own-network"` | no |
| boot\_volume\_size | Size in GiB of a root volume created from the image; null boots from the flavor's local disk. | `number` | `null` | no |
| certificates | Certificates of the domains of the services (ADR-0008): obtained and renewed by lego on each instance, through<br/>the ACME DNS-01 challenge, from any ACME directory (Let's Encrypt, or the organisation's<br/>authority). null runs the demonstration mode: a self-signed certificate, with a warning at<br/>every plan.<br/>- directory\_url: the ACME directory, for example<br/>  "https://acme-v02.api.letsencrypt.org/directory".<br/>- ca\_bundle: root certificate (PEM) of an authority that is not publicly trusted.<br/>- email: contact of the ACME account.<br/>- dns.provider: a lego DNS provider code, for example "rfc2136".<br/>- dns.settings: for rfc2136, nameserver ("host:port"), tsig\_key\_name, tsig\_algorithm and<br/>  tsig\_secret; for any other provider, its lego environment variables, as documented by lego.<br/>- dns.resolvers: name servers ("host:port") lego checks the TXT record on, and only on;<br/>  empty uses the instance's resolvers and the zone's authoritative servers.<br/>The settings reach the instances through their user data, readable by the members of the<br/>project: give a key restricted to the \_acme-challenge records of these domains. | <pre>object({<br/>    directory_url = string<br/>    ca_bundle     = optional(string)<br/>    email         = string<br/>    dns = object({<br/>      provider  = string<br/>      settings  = map(string)<br/>      resolvers = optional(list(string), [])<br/>    })<br/>  })</pre> | `null` | no |
| cidr | Range of the service's network. On a hub plane, the attachment's cidr in shared/planes; on a plane without NAT it must be unique (stack shared/planes checks it). | `string` | `"10.35.0.0/27"` | no |
| consumers | Who may use the services on the internal services plane, as CIDRs: the internal\_sources output<br/>of each consuming tenant, and the ranges of the users as the service sees them. Admitted on the<br/>ports of the services only. Empty keeps the services closed, as when the service is created<br/>before its consumers. Network admission does not identify a user: authentication belongs to<br/>the service. | `list(string)` | `[]` | no |
| dns | Where the records of internal\_zone go (ADR-0016, D2): "designate", written in the cloud's Designate, or "output", written nowhere, for your DNS provider. The dns\_records output gives them in both cases. | `string` | `"designate"` | no |
| dns\_nameservers | DNS resolvers of the service's network, reachable through its routes; empty (the default), those of Neutron's DHCP. A service without egress takes a resolver behind one of its planes (ADR-0016, D3). | `list(string)` | `[]` | no |
| egress\_network | External network of the egress router (egress = "router"). The instances get no public address on it. subnet: optional, the subnet of that network to look up by name; without it, Neutron chooses (a public network with several subnets of the same name). null with egress = "none". | <pre>object({<br/>    network = string<br/>    subnet  = optional(string)<br/>  })</pre> | `null` | no |
| instance\_count | Number of instances, spread over the zones. Above one, an internal load balancer per service is its address (ADR-0006, D1); with one, the instance itself. | `number` | `2` | no |
| internal\_zone | Zone of the internal names: the records of the domains of services, in the dns\_records output. With<br/>dns = "designate", the stack writes them in this Designate zone, owned by or shared with this<br/>project. null: no records, the domains output gives the names and their address.<br/>- name (with its trailing dot): the zone; id: its Designate ID, needed with dns = "designate".<br/>- ttl: of the records. | <pre>object({<br/>    id   = optional(string)<br/>    name = string<br/>    ttl  = optional(number, 300)<br/>  })</pre> | `null` | no |
| lego\_version | Version of lego installed on the instances (release archive from GitHub), pinned. | `string` | `"5.6.0"` | no |
| monitoring | Monitoring as a push integration point (ADR-0007): each instance runs its exporters and a<br/>Prometheus agent that pushes to the receiver through the observability plane. Nothing connects<br/>into the instances for their metrics.<br/>- receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output<br/>  receiver\_url of the receiver); null runs no agent. | <pre>object({<br/>    receiver = optional(string)<br/>  })</pre> | `{}` | no |
| name | Name of the shared service, in the names of its resources (<site>-<name>) and in the labels of its metrics. Two shared services of one site need two names. | `string` | `"service"` | no |
| network\_mtu | MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes they join (planes contract): a larger value creates a<br/>path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator<br/>enables it. null keeps the cloud default. | `number` | `null` | no |
| server\_group\_policy | Placement of the instances: "anti-affinity" or "soft-anti-affinity". | `string` | `"anti-affinity"` | no |
| services | The services offered on the internal services plane, keyed by name, each at its own address:<br/>an internal load balancer with a TCP listener per port when there are several instances, the<br/>instance itself otherwise.<br/>- ports: the TCP ports the workload listens on.<br/>- sources: who may connect; the consumers by default.<br/>- domains: the names of the service: records in internal\_zone, and the names of the<br/>  certificate of the instances.<br/>The default is the demonstration: HTTP on 8080 (HTTPS with certificates). | <pre>map(object({<br/>    ports   = list(number)<br/>    sources = optional(list(string))<br/>    domains = optional(list(string), [])<br/>  }))</pre> | <pre>{<br/>  "demo": {<br/>    "ports": [<br/>      8080<br/>    ]<br/>  }<br/>}</pre> | no |
| shared\_egress | The shared egress of the landing zone, with egress = "shared": proxy, the URL of the proxy output of stack shared/egress, where this service is declared with its internal\_sources and its names (ADR-0016, D1). | <pre>object({<br/>    proxy = string<br/>  })</pre> | `null` | no |
| tls\_reload | Command the ACME client runs after each issuance and renewal, for the workload to load the certificate (/etc/shared-service/tls/cert.pem and key.pem). null: the demonstration's restart, or nothing with your workload. | `string` | `null` | no |
| volume\_zones | Block storage zone of the root volumes (boot\_volume\_size), for each compute zone. A compute zone missing from the map gets the cloud's default storage zone. | `map(string)` | `{}` | no |
| workload | The workload, added to the cloud-init of each instance (the form of the tenant module's<br/>cloudinit): packages to install, files to write (path => { content, permissions, owner }),<br/>commands to run at first boot. The stack does not template it: a setting that depends on the<br/>instance reads the instance metadata. null runs the demonstration on the ports of services:<br/>HTTP, or HTTPS with the certificate of the instance. | <pre>object({<br/>    packages = optional(list(string), [])<br/>    write_files = optional(map(object({<br/>      content     = string<br/>      permissions = optional(string)<br/>      owner       = optional(string)<br/>    })), {})<br/>    runcmd = optional(list(string), [])<br/>  })</pre> | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bastion | Floating IP of the bastion on the administration network, or null. |
| dns\_records | The records of the domains of services in internal\_zone (ADR-0016, D2), keyed "<name> <type>", each { zone, name, type, ttl, records }: written in Designate with dns = "designate", to publish with your DNS provider otherwise (a for\_each of its record resource). Empty without internal\_zone. |
| domains | Names of the services and the address they resolve to; as records, in dns\_records. |
| instances | Instances and their private addresses. |
| services | What the consumers reach, on the internal services plane: each service and its "address:port" entries, at a floating IP of the plane with NAT, at its address in the service's network otherwise. The consumers admit nothing from the service for them. |
| sources | Addresses the service connects from on the internal services plane, for the admission rules of what it calls (allowed\_sources): its router's gateway address on a plane with NAT, its range on a plane without NAT. |
<!-- END_TF_DOCS -->
