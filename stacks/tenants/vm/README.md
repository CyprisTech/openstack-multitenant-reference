# Tenant type `vm`

Instances serving several domains behind **one service address** ([ADR-0006](../../../docs/adr/0006-exposure.md)):

- `instance_count` instances (2 by default) in a server group (anti-affinity) on the tenant network;
- with more than one instance, an Octavia load balancer in TCP on 443 is the service address; with one, the instance itself;
- the service address is published through the shared entry point (`exposure = "entry-point"`, the default), admitting the entry point's addresses only (`edge_sources`), or exposed with its own public floating IP (`exposure = "public"`);
- on the publication plane, the service address is a floating IP of the plane when it translates addresses, its own address otherwise; the instances have no address on the planes;
- routers to the egress network (default route), the publication and observability planes, with plane routes pushed by DHCP;
- metrics pushed to your receiver by a Prometheus agent on each instance (`monitoring.receiver`); nothing connects into the instances;
- an optional bastion for administration.

The web server is a demonstration backend: nginx terminates TLS, accepts the PROXY protocol v2 header from its load balancer only, and answers with the host, the server name and the client address it received.

**Certificates** ([ADR-0008](../../../docs/adr/0008-tenant-certificates.md)). With `certificates`, each instance runs lego ([`modules/acme-client`](../../../modules/acme-client/README.md)): it obtains the certificate of the domains through the ACME DNS-01 challenge, from Let's Encrypt or the organisation's authority, renews it when it is due (checked every hour), and enables the site once the certificate is issued; until then the load balancer keeps the instance out of its pool. The DNS provider's settings are written to `/etc/lego/dns.env`, readable by root only, through the instance's user data, which the members of the project can read: give a key restricted to the `_acme-challenge` records of the domains. Without `certificates`, the tenant runs in **demonstration mode**: a self-signed certificate, and a warning at every plan.

The tenant joins the internal services plane when its entry of the `shared/planes` attachments has it, for instance to reach the organisation's certificate authority; its `internal_sources` output gives the addresses the services of that plane must admit.

```mermaid
flowchart LR
    EP["entry point"] --> PUB[["publication plane"]]
    PUB --> SA["service address<br/>load balancer, or the instance"]
    SA --> VM["instances<br/>nginx terminates TLS · lego"]
    VM -->|"metrics"| MON[["observability plane"]]
    MON --> RCV["receiver"]
    VM -->|"ACME, DNS-01 updates<br/>optional"| INT[["internal services plane"]]
    INT --> CA["certificate authority, DNS"]
    VM -->|"default route"| EG["egress network<br/>packages, public ACME"]
    ADM(["Administrators"]) -->|"SSH"| BA["bastion<br/>optional"]
    BA --> VM

    classDef shared fill:#dbeafe,stroke:#1d4ed8,color:#1e3a8a
    classDef plane fill:#f3f4f6,stroke:#4b5563,color:#111827
    classDef tenant fill:#ffedd5,stroke:#c2410c,color:#7c2d12
    classDef outside fill:#ffffff,stroke:#6b7280,color:#111827
    classDef other fill:#ffffff,stroke:#6b7280,color:#111827,stroke-dasharray:4 3
    class SA,VM,BA tenant
    class PUB,MON,INT plane
    class EP,RCV,CA,EG other
    class ADM outside
```

Arrows show who opens the connection. With `exposure = "public"`, the service address gets a public floating IP instead of the entry point. Solid boxes: created by this stack; dashed boxes: provided by other stacks or outside the landing zone; grey: planes.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

The stack uses the `cloud` entry of `clouds.yaml` given in `terraform.tfvars`. Make sure no `OS_*` variable is set in the shell.

## Publishing the domains on the entry point

The `published_domains` output maps each domain to the service address, in the shape of the `domains` input of the entry point. [`scripts/publish-domains.sh`](../../../scripts/publish-domains.sh) gathers it from every tenant and applies the entry point. With `exposure = "public"`, the output is empty: point the domains to the `service_address` output instead.

## Requirements

- **MTU.** Set `network_mtu` to the smallest of the tenant overlay MTU and the plane MTUs (planes contract). A larger value lets TCP connections open but drops large packets: the TLS handshake then hangs.
- **Range.** `web_cidr` must avoid the ranges reserved by the cloud; on hub planes, it must also be the range of the attachment in `shared/planes`.
- **Internet access at first boot.** The egress network must route to the Internet and the resolvers must be reachable through it (package installation).

## Bastion

With `bastion` set, the stack creates a small network whose only router joins the administration network, and a bastion with a floating IP on it and a second port on the web network. SSH to the web instances is admitted from the bastion only.

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

### Providers

| Name | Version |
| ---- | ------- |
| openstack | ~> 3.2 |
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| acme | ../../../modules/acme-client | n/a |
| admission | ../../../modules/admission | n/a |
| bastion | ../../../modules/bastion | n/a |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.5 |
| metrics | ../../../modules/metrics-agent | n/a |
| planes | ../../../modules/plane-attachment | n/a |
| web | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | v0.1.5 |

### Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.checks](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [openstack_networking_router_v2.internal](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_router_v2) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| az | Availability zone of the instances. | `string` | n/a | yes |
| cloud | Entry of clouds.yaml used by this stack. | `string` | n/a | yes |
| egress\_network | External network giving the default route (package installation). The instances get no public address on it; with exposure = "public", the service address is a floating IP of this network. | <pre>object({<br/>    network = string<br/>    subnet  = string<br/>  })</pre> | n/a | yes |
| flavor | Flavor name of the instances. | `string` | n/a | yes |
| image | Image name of the instances (an Ubuntu LTS cloud image). | `string` | n/a | yes |
| plane\_attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),<br/>keyed by plane: how its router joins each plane and how its instances are seen there,<br/>whatever provides the plane (the operator, or a hub project). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| site | Short site name; must match the site of the entry point (stack shared/entry-point). | `string` | n/a | yes |
| admin | Administration access: users (login => SSH public keys, sudo granted) and SSH source ranges. No access by default. | <pre>object({<br/>    users     = optional(map(list(string)), {})<br/>    ssh_cidrs = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| bastion | Optional administration bastion. It lives in its own small network whose router joins<br/>external\_network (an administration network such as an intranet) and carries a floating<br/>IP on it. A second port on the web network gives it access to the instances; the web<br/>network itself gets no route to the administration network.<br/>- ssh\_cidrs: sources allowed to reach the bastion on port 22.<br/>The users of var.admin are created on the bastion and on the instances. | <pre>object({<br/>    external_network = object({ network = string, subnet = string })<br/>    cidr             = optional(string)<br/>    flavor           = optional(string)<br/>    ssh_cidrs        = list(string)<br/>  })</pre> | `null` | no |
| boot\_volume\_size | Size in GiB of a root volume created from the image; null boots from the flavor's local disk. | `number` | `null` | no |
| certificates | Certificates of the domains (ADR-0008): obtained and renewed by lego on each instance, through<br/>the ACME DNS-01 challenge, from any ACME directory (Let's Encrypt, or the organisation's<br/>authority). null runs the demonstration mode: a self-signed certificate, with a warning at<br/>every plan.<br/>- directory\_url: the ACME directory, for example<br/>  "https://acme-v02.api.letsencrypt.org/directory".<br/>- ca\_bundle: root certificate (PEM) of an authority that is not publicly trusted.<br/>- email: contact of the ACME account.<br/>- dns.provider: a lego DNS provider code, for example "rfc2136".<br/>- dns.settings: for rfc2136, nameserver ("host:port"), tsig\_key\_name, tsig\_algorithm and<br/>  tsig\_secret; for any other provider, its lego environment variables, as documented by lego.<br/>- dns.resolvers: name servers ("host:port") lego checks the TXT record on, and only on;<br/>  empty uses the instance's resolvers and the zone's authoritative servers.<br/>The settings reach the instances through their user data, readable by the members of the<br/>project: give a key restricted to the \_acme-challenge records of these domains. | <pre>object({<br/>    directory_url = string<br/>    ca_bundle     = optional(string)<br/>    email         = string<br/>    dns = object({<br/>      provider  = string<br/>      settings  = map(string)<br/>      resolvers = optional(list(string), [])<br/>    })<br/>  })</pre> | `null` | no |
| dns\_nameservers | DNS resolvers of the tenant network, reachable through its routes. | `list(string)` | `[]` | no |
| domains | Domains served by the instances and published through the entry point. | `list(string)` | <pre>[<br/>  "site-a.example.org",<br/>  "site-b.example.org"<br/>]</pre> | no |
| edge\_sources | Ranges the entry point connects from on publication, in CIDR notation: output<br/>publication\_sources of stack shared/entry-point. Only they may reach the service address.<br/>Required with exposure = "entry-point". | `list(string)` | `[]` | no |
| exposure | How the service address is published (ADR-0006, D2):<br/>- "entry-point": through the shared entry point (output published\_domains), reachable from<br/>  the entry point only;<br/>- "public": a floating IP of egress\_network, reachable from anywhere; the shared entry point<br/>  is not used. | `string` | `"entry-point"` | no |
| instance\_count | Number of instances. Above one, a load balancer is the service address (ADR-0006, D1); with one, the instance itself. | `number` | `2` | no |
| lego\_version | Version of lego installed on the instances (release archive from GitHub), pinned. | `string` | `"5.6.0"` | no |
| monitoring | Monitoring as a push integration point (ADR-0007): each instance runs its exporters and a<br/>Prometheus agent that pushes to the receiver through the observability plane. Nothing connects<br/>into the instances for their metrics.<br/>- receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output<br/>  receiver\_url of the receiver); null runs no agent. | <pre>object({<br/>    receiver = optional(string)<br/>  })</pre> | `{}` | no |
| network\_mtu | MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes they join (planes contract): a larger value creates a<br/>path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator<br/>enables it. null keeps the cloud default. | `number` | `null` | no |
| server\_group\_policy | Placement of the instances: "anti-affinity" or "soft-anti-affinity". | `string` | `"anti-affinity"` | no |
| web\_cidr | Range of the tenant network. On planes with NAT tenants may reuse the same range; on planes without NAT it must be unique (stack shared/planes checks it). | `string` | `"10.21.0.0/24"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bastion | Floating IP of the bastion on the administration network, or null. |
| edge\_sources | Addresses of the entry point admitted on the service address. |
| instances | Web instances and their private addresses. |
| internal\_sources | Addresses the tenant reaches the internal services plane from, for the services of that plane (allowed\_sources): its router's gateway address on a plane with NAT, the tenant range on a plane without NAT. Empty when the tenant does not join the plane. |
| published\_domains | Domains to publish through the entry point and their service address, for its domains input (scripts/publish-domains.sh). Empty with exposure = "public". |
| service\_address | The tenant's service address, "address:443" (ADR-0006, D1): its load balancer, or its only instance. On publication through the entry point (a floating IP of the plane when it translates addresses, the address itself otherwise), or a public floating IP with exposure = "public". |
<!-- END_TF_DOCS -->
