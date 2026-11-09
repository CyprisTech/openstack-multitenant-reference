# Trade-offs

Every choice of this architecture has a cost. This document states each one: what was chosen, why, what it costs, and when the alternative is the better choice. The decisions themselves are recorded in the [ADRs](../adr/README.md).

| # | Topic | Choice |
|---|---|---|
| 1 | [TLS at the public entry point](#1-tls-passthrough-at-the-public-entry-point) | SNI routing, TLS passthrough |
| 2 | [Health monitors](#2-health-monitors) | TCP checks on the Traefik port |
| 3 | [PROXY protocol](#3-proxy-protocol-end-to-end) | Client address carried end to end |
| 4 | [Octavia topology](#4-octavia-topology) | Chosen per load balancer flavor |
| 5 | [The shared entry point](#5-the-shared-entry-point) | Shared by the tenants that choose it; others expose themselves |
| 6 | [Regions and sites](#6-regions-and-sites) | Planes and an entry point per region, hubs joined by an overlay, failover by DNS |
| 7 | [Isolation on the publication plane](#7-isolation-on-the-publication-plane) | Shared plane, service addresses admitting the entry point only |
| 8 | [Security groups ownership](#8-tenant-owned-security-groups-or-a-central-catalogue) | Owned by each tenant |
| 9 | [Kubernetes lifecycle](#9-kubernetes-with-cluster-api) | Cluster API Provider OpenStack |
| 10 | [Where the planes come from](#10-where-the-planes-come-from) | Operator planes with NAT, or hub planes with a transit router, or routed operator planes |
| 11 | [Administration and internal services](#11-one-network-for-administration-and-internal-services) | Two roles; one network accepted with specific sources |
| 12 | [Add-ons and GitOps](#12-add-ons-declared-with-cluster-api-not-gitops) | CAAPH next to the cluster; GitOps-ready |
| 13 | [Kubelet certificates](#13-kubelet-serving-certificates-from-the-cluster-ca) | Signed by the cluster CA, approved per node |
| 14 | [Node image size](#14-node-image-size) | Smallest image; disks sized per role by the cluster |
| 15 | [Monitoring by push](#15-monitoring-by-push) | Agents push to a receiver; nothing connects into a tenant |
| 16 | [Routes through instance metadata](#16-routes-through-instance-metadata) | Updated in place, read by a timer |
| 17 | [Certificates through DNS-01 only](#17-certificates-through-dns-01-only) | DNS-01 from any ACME directory; HTTP-01 not shipped |

## 1. TLS passthrough at the public entry point

**Choice.** Octavia forwards raw TCP; Traefik reads the server name (SNI) in the TLS ClientHello and forwards the bytes to the right backend without decrypting them.

**Why.** Private keys never leave the backends; the edge holds no certificate of the tenants; adding a domain is one route, with no certificate to deploy on shared infrastructure; any TLS protocol works, not only HTTP.

**Cost.**

- No L7 features at the edge: no path or header routing, no WAF, no HTTP rate limiting, no HTTP access log. The edge can only limit connections.
- Each tenant manages its own certificates. The reference uses ACME DNS-01 challenges on the tenant's own zone ([ADR-0006](../adr/0006-exposure.md), D5): they work with several instances and for wildcards, and ask nothing of the entry point, whose port 80 only redirects to HTTPS.
- Clients that send no SNI cannot be routed.
- If a backend enables Encrypted Client Hello, the edge only sees the outer, public name and can no longer route on the real one.

**Alternative.** Terminate TLS at the edge (Traefik or Octavia `TERMINATED_HTTPS` with Barbican), then re-encrypt to the backends.

**Choose it when** you need a WAF, central HTTP policies or L7 routing, and you accept that the edge holds every tenant's private key.

## 2. Health monitors

**Choice.** TCP checks on port 443 of each Traefik instance.

**Why.** A PING check only proves that the VM answers ICMP: a stopped Traefik would keep receiving traffic. A TCP check proves that the port accepts connections.

**Cost.** It does not prove that Traefik routes correctly or that backends are up. An HTTP check would need a dedicated plain HTTP endpoint on Traefik, outside the PROXY-protocol entry points.

**Alternative.** HTTP check on a Traefik health endpoint exposed on a separate port.

**Choose it when** a listening but unhealthy proxy is a failure mode you have actually seen.

## 3. PROXY protocol end to end

**Choice.** Octavia adds a PROXY header towards Traefik; Traefik sends PROXY protocol v2 to the tenant's service address. **Exactly one header reaches each backend.** The tenant's load balancer passes the entry point's header through instead of adding its own (TCP pools; on Kubernetes, no `proxy-protocol` annotation), and the backends trust the header from the load balancer's addresses only. On Kubernetes, the Service uses `externalTrafficPolicy: Local` so that Traefik sees the load balancer, a trusted peer.

**Why.** Without it, every backend sees the edge address as the client. Logs, rate limits and allow lists on the backends need the real client address, and TLS passthrough leaves no `X-Forwarded-For` header to carry it.

**Cost.** Every hop must agree. A backend that does not expect the header fails every connection, and a backend that accepts it from untrusted sources lets clients forge their address. Traefik only trusts the header from its load balancer's network (`trustedIPs`), and each backend only from its own load balancer's.

The Kubernetes case adds two costs: a second header breaks the TLS handshake within milliseconds (seen in the tests), and with `externalTrafficPolicy: Local` only the nodes running Traefik receive traffic, so Traefik runs on several nodes.

**Alternative.** No PROXY protocol: simpler, but client addresses are lost.

## 4. Octavia topology

**Choice.** The topology (one amphora, or an active/standby pair) comes from the load balancer flavor offered by the cloud; the stack takes a flavor, not a topology.

**Why.** Topology is an operator setting in Octavia, not a tenant attribute. Consumers choose among the flavors their cloud offers.

**Cost.**

| Topology | Failover | Resources |
|---|---|---|
| Single amphora | Octavia rebuilds the amphora: minutes of outage | One amphora VM |
| Active/standby | VRRP failover between two amphorae: seconds | Two amphora VMs |

**Recommendation.** Active/standby for the entry point when the cloud offers it: every domain published through it depends on that load balancer (see 5).

## 5. The shared entry point

**Choice.** One entry point for the domains of every tenant that chooses it; a tenant may instead expose its service address with its own public floating IP ([ADR-0006](../adr/0006-exposure.md), D2).

**Why.** Many domains behind one public IPv4 address and one load balancer, with TLS kept by each tenant: the need of a host with many small customers, where an address and a load balancer per tenant cost more than the service.

**Cost.** Its failure or misconfiguration affects every tenant published through it. Mitigations: two Traefik replicas on different hosts, an active/standby load balancer, routes kept as version-controlled configuration and delivered without replacing instances. It is not the usual design across projects, where each project exposes itself with its own load balancer.

**Choose a tenant's own address when** the tenant needs an independent failure domain, its own exposure policy, or a WAF in front of it.

## 6. Regions and sites

**Choice.** Each region has its own planes, hub and entry point; the hubs are joined by an encrypted overlay; the entry points fail over by DNS (active/passive).

**Why.** Neutron networks, Octavia load balancers and their amphorae live in one region: a design that spans regions must join them above Neutron. An overlay works on any OpenStack cloud, unlike provider features such as OVHcloud's vRack.

**Cost.** Failover is not instantaneous (DNS TTL), and the passive entry point and the overlay must be kept tested. Stateful data (volumes, databases) is not replicated by the reference: the tenants replicate it, or restore it through the backup integration point.

**Choose active-active when** the downtime of a DNS failover is not acceptable and the tenants' data is replicated: it needs a global load balancing service outside OpenStack.

## 7. Isolation on the publication plane

**Choice.** The tenants' service addresses are on the shared publication plane; each admits the entry point only (load balancer sources, `edge_sources`). Instances are not on the plane.

**Why.** One plane serves every tenant: no per-tenant network between the entry point and each tenant.

**Cost.** At the network level, every project attached to the publication plane can reach every service address on it: isolation rests on the load balancers' sources and the security groups, without a firewall in between. The sources must match the address the service actually sees: the entry point's router address on a plane with address translation, its own addresses on a routed plane (output `publication_sources`).

**Alternative.** A firewall at the hub, between the plane and the tenants (OVHcloud's landing zone does so), or a dedicated transit network per tenant.

**Choose it when** the tenants do not trust each other and you can run a firewall in high availability: a wrong rule on one tenant no longer opens a path.

## 8. Tenant-owned security groups or a central catalogue

**Choice.** Each tenant declares its own security groups. A central catalogue shared by RBAC is an operator option, with [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-tenant).

**Why.** It works on any cloud, with one project or many, and needs no admin rights. Rules between tenants use CIDRs because `remote_group_id` only works inside one project.

**Cost.** Common rules (SSH from an administration network) are repeated in every tenant and can drift.

**Alternative.** A central catalogue of security groups owned by the operator and shared with the projects by RBAC.

**Choose it when** one team governs the network rules of every tenant and wants a single place to change them.

## 9. Kubernetes with Cluster API

**Choice.** Terraform prepares the project; Cluster API Provider OpenStack creates and maintains the clusters.

**Why.** Cluster API handles the lifecycle Terraform handles badly: rolling upgrades, node replacement, scaling. It needs only project-level rights.

**Cost.** Two tools and two states: Terraform for the infrastructure, Cluster API objects for the clusters. Node images must be built and kept current with image-builder. This reference makes the cluster **self-managed** (`clusterctl move`): no management cluster to run, but a broken cluster cannot repair itself; the repair path is to move Cluster API back to a temporary kind cluster (what `delete-cluster.sh` does). The glue between Terraform and Cluster API is a shell script on a bootstrap instance, and the cluster credential is created by an administrator, outside Terraform, so that no secret is in the state.

**Choose a dedicated management cluster when** you run several clusters: it manages them all and survives the loss of any one.

**Alternative.** A managed Kubernetes service (Magnum or the cloud's own offer).

**Choose it when** your cloud offers one and its versions and options suit you: you give up control for less to operate.

## 10. Where the planes come from

**Choice.** A plane is described by two properties, how a tenant router joins it and whether addresses are translated ([ADR-0004](../adr/0004-planes-and-isolation.md)). Three cases follow: external networks of the cloud operator joined with source NAT, the same routed in a shared address scope, and networks of a hub project shared by RBAC and joined through a transit router.

| | Operator planes, NAT | Hub planes, routed | Operator planes, routed |
|---|---|---|---|
| Rights | the operator creates them | member role | the operator, with address scopes |
| Tenant ranges | may overlap | unique (checked) | unique, from subnet pools |
| A tenant is seen at | its router's address; floating IPs for service addresses | its own addresses | its own addresses |
| Routing | none to maintain | static routes on the transit router, discovered at each apply | advertised (BGP) |
| Limits | one floating IP per address that others must reach | about 30 attachments per plane (`max_routes`); RBAC sharing may be forbidden (scs-0126); project and RBAC quotas | needs dynamic routing towards the tenants |

**Why.** Operator planes with NAT are the only option when tenants keep their own ranges and the operator has no dynamic routing; hub planes are the only option with a member role. OpenStack has no native peering between projects: the hub plays, between projects within one region, the role a transit gateway plays on other clouds. The closest published design, OVHcloud's landing zone, puts a firewall at the hub.

**Cost.** Two cases to test, and a stack (`shared/planes`) applied twice when a tenant joins a hub plane (sharing, then routes).

**Choose routed operator planes when** you run the cloud, coordinate the addressing and advertise the tenant ranges: no translation, no static routes.

## 11. One network for administration and internal services

**Choice.** Administration (bastions, Kubernetes API) and internal services are two roles. One network may carry both, provided the administration endpoints admit **specific administrator addresses**, never the network range.

**Why.** Many clouds have a single internal network. A tenant joining the internal services plane appears there with an address of its range (source NAT): admitting the range would let any workload of that tenant reach every bastion and API.

**Cost.** Administrator addresses must be known and kept current, and they are often router addresses, easy to guess wrong (see the [test results](test-results.md)).

**Choose two networks when** you can: the administration network then admits nobody but administrators by construction.

## 12. Add-ons declared with Cluster API, not GitOps

**Choice.** Cluster API Add-on Provider Helm (CAAPH) installs the add-ons, declared next to the cluster and moved with it.

**Why.** One tool and one set of objects for the cluster and its add-ons; nothing more to install.

**Cost.** CAAPH does not correct drift: a manual change to an add-on stays until the chart values change. Release names must be fixed, or a new reconciliation installs a chart twice.

**Choose GitOps (Flux or Argo CD) when** several people change the clusters: drift becomes visible and reverted. The manifests are plain YAML rendered by the stack, so a GitOps tool can reconcile them without change.

## 13. Kubelet serving certificates from the cluster CA

**Choice.** Kubelets request serving certificates from the cluster CA (`rotate-server-certificates`); kubelet-csr-approver approves them for this cluster's node names and addresses only; metrics-server verifies them.

**Why.** The common shortcut, metrics-server with `--kubelet-insecure-tls`, accepts any certificate presented by anything that answers on the kubelet port.

**Cost.** One more controller, and a policy (node name pattern, address range) to keep in line with the cluster.

## 14. Node image size

**Choice.** The node image is built on a small volume (8 GiB); the root disk of each node is chosen by the cluster, per role.

**Why.** The virtual size of the image is the minimum disk of every node. A 20 GiB image forced 20 GiB per node, test clusters included.

**Cost.** None at run time: cloud-init grows the root partition to the disk each machine gets.

## 15. Monitoring by push

**Choice.** Each tenant pushes its metrics to a receiver of the shared services (Prometheus remote write; OTLP for workloads that use it); nothing on the observability plane connects into a tenant ([ADR-0007](../adr/0007-monitoring.md)).

**Why.** Pulling is how Prometheus works and stays the practice inside one network or cluster; across tenant boundaries, pushing is the common practice: the only flow is outbound from the tenant, no metrics port is open to a central server, and no instance needs an address on the observability plane.

**Cost.** An agent runs in every tenant. A target that stops pushing is detected by the absence of its series, not by a failed scrape (`up`). Sources are identified by labels, which a tenant could forge: the receiver trusts what the tenants push.

**Choose pulling when** the server and its targets are in one trust domain and one network.

## 16. Routes through instance metadata

**Choice.** The entry point's routes are metadata items of its instances, updated in place by OpenTofu or Terraform; a timer on each instance renders them into Traefik's dynamic configuration ([ADR-0006](../adr/0006-exposure.md), D3).

**Why.** Publishing a domain is the most frequent change of a host; replacing the instances for each one was slow (5 to 8 minutes) and lost requests. The metadata service needs neither SSH from the deployer nor another service, and exists on every OpenStack cloud.

**Cost.** About 120 domains per entry point (Nova quota `metadata_items`); a delay of seconds before a change is applied; routes are readable by the project's members (they hold no secret).

**Choose object storage or a key-value store when** the cloud has one and the number of domains exceeds the metadata quota.

## 17. Certificates through DNS-01 only

**Choice.** Tenants obtain their certificates with the ACME DNS-01 challenge, from Let's Encrypt or the organisation's authority ([ADR-0008](../adr/0008-tenant-certificates.md)).

**Why.** DNS-01 works for published and internal names alike, for any number of instances behind a load balancer, allows wildcard certificates, needs no inbound port 80, and fits an entry point that does not decrypt.

**Cost.** The tenant needs write access to its DNS zone, through a provider supported by its tool; the credentials reach the instances or the cluster and must be restricted to the `_acme-challenge` records. With Let's Encrypt, the zone must resolve publicly (or `_acme-challenge` be a CNAME to a public zone), and every certificate appears in the public Certificate Transparency logs.

**Choose HTTP-01 when** a tenant is published on the Internet, cannot get write access to its zone, and terminates TLS on one place (an ingress or a reverse-proxy tier): the entry point would then forward `/.well-known/acme-challenge/` on port 80 to the tenant. It cannot work for several instances behind a load balancer, each requesting its own certificate.

## Evidence

The architecture is tested on a real cloud, with the findings that shaped several choices above: [test results](test-results.md).

The module this architecture builds on is tested on a real cloud: apply, empty plan after apply, destroy. Results are in the module's [testing report](https://github.com/CyprisTech/terraform-openstack-tenant/blob/main/docs/testing.md).
