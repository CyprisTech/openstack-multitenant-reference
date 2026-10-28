# Trade-offs

Every choice of this architecture has a cost. This document states each one: what was chosen, why, what it costs, and when the alternative is the better choice. The decisions themselves are recorded in [ADR-0001](adr/0001-reference-architecture.md).

| # | Topic | Choice |
|---|---|---|
| 1 | [TLS at the public entry point](#1-tls-passthrough-at-the-public-entry-point) | SNI routing, TLS passthrough |
| 2 | [Health monitors](#2-health-monitors) | TCP checks on the Traefik port |
| 3 | [PROXY protocol](#3-proxy-protocol-end-to-end) | Client address carried end to end |
| 4 | [Octavia topology](#4-octavia-topology) | Chosen per load balancer flavor |
| 5 | [The edge as a shared dependency](#5-the-edge-as-a-shared-dependency) | One entry point for every domain |
| 6 | [One site in v1](#6-one-site-in-v1) | One site, site-ready code |
| 7 | [Isolation on `svc_public`](#7-isolation-on-the-svc_public-plane) | Shared plane, isolation by security groups |
| 8 | [Security groups ownership](#8-tenant-owned-security-groups-or-a-central-catalogue) | Owned by each tenant |
| 9 | [Kubernetes lifecycle](#9-kubernetes-with-cluster-api) | Cluster API Provider OpenStack |
| 10 | [Layer 10](#10-layer-10-provided-by-the-operator) | Provided by the operator until cloud-baseline |
| 11 | [Administration and intranet](#11-one-network-for-administration-and-intranet) | Two roles; one network accepted with specific sources |
| 12 | [Add-ons and GitOps](#12-add-ons-declared-with-cluster-api-not-gitops) | CAAPH next to the cluster, no GitOps yet |
| 13 | [Kubelet certificates](#13-kubelet-serving-certificates-from-the-cluster-ca) | Signed by the cluster CA, approved per node |
| 14 | [Node image size](#14-node-image-size) | Smallest image; disks sized per role by the cluster |

## 1. TLS passthrough at the public entry point

**Choice.** Octavia forwards raw TCP; Traefik reads the server name (SNI) in the TLS ClientHello and forwards the bytes to the right backend without decrypting them.

**Why.** Private keys never leave the backends; the edge holds no certificate of the tenants; adding a domain is one route, with no certificate to deploy on shared infrastructure; any TLS protocol works, not only HTTP.

**Cost.**

- No L7 features at the edge: no path or header routing, no WAF, no HTTP rate limiting, no HTTP access log. The edge can only limit connections.
- Each backend manages its own certificates. HTTP-01 challenges do not reach a backend through an edge that redirects port 80: backends use DNS-01 or TLS-ALPN-01 (which works through passthrough because it is answered inside the TLS handshake), or the edge routes `/.well-known/acme-challenge/` per domain on port 80.
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

**Choice.** Octavia adds a PROXY header towards Traefik; Traefik sends PROXY protocol v2 to the backends. **Exactly one header reaches each backend.** When the backend is itself behind a load balancer (the `platform` ingress), that load balancer passes the entry point's header through instead of adding its own (TCP pools, no `proxy-protocol` annotation), and the Service uses `externalTrafficPolicy: Local` so that Traefik sees the load balancer, a trusted peer.

**Why.** Without it, every backend sees the edge address as the client. Logs, rate limits and allow lists on the backends need the real client address, and TLS passthrough leaves no `X-Forwarded-For` header to carry it.

**Cost.** Every hop must agree. A backend that does not expect the header fails every connection, and a backend that accepts it from untrusted sources lets clients forge their address. Traefik only trusts the header from the load balancer subnet (`trustedIPs`), and each backend must do the same with the edge addresses.

The `platform` case adds two costs: a second header breaks the TLS handshake within milliseconds (seen in the tests), and with `externalTrafficPolicy: Local` only the nodes running Traefik receive traffic, so Traefik runs on several nodes.

**Alternative.** No PROXY protocol: simpler, but client addresses are lost.

## 4. Octavia topology

**Choice.** The topology (one amphora, or an active/standby pair) comes from the load balancer flavor offered by the cloud; the stack takes a flavor, not a topology.

**Why.** Topology is an operator setting in Octavia, not a tenant attribute. Consumers choose among the flavors their cloud offers.

**Cost.**

| Topology | Failover | Resources |
|---|---|---|
| Single amphora | Octavia rebuilds the amphora: minutes of outage | One amphora VM |
| Active/standby | VRRP failover between two amphorae: seconds | Two amphora VMs |

**Recommendation.** Active/standby for the public edge when the cloud offers it: every domain depends on that load balancer (see 5).

## 5. The edge as a shared dependency

**Choice.** One entry point for every domain of every tenant.

**Why.** One public address, one place for connection limits and access logs, one component to harden and monitor.

**Cost.** Its failure or misconfiguration affects every tenant at once. Mitigations: two Traefik replicas on different hosts, an active/standby load balancer, routes kept as version-controlled configuration.

**Alternative.** One load balancer per tenant, each with its own public address.

**Choose it when** tenants need independent failure domains or different exposure policies more than they need a single entry point.

## 6. One site in v1

**Choice.** Version 1 runs in one site (one region or availability zone). The code is site-ready: the site is an input of every stack, and no address is written by hand.

**Why.** An Octavia load balancer and its amphorae live in one site. Failover between sites needs a standby edge, a DNS switch and a tested runbook: a version of its own.

**Cost.** In v1, a site outage takes the entry point down. Recovery is a cold rebuild: deploy the same stacks in another site, then change the DNS records. Stateful data (volumes, databases) is not replicated; recovering it needs a backup and restore that this repository does not provide.

**Next.** A later version adds an edge per site (active/passive), a failover runbook with a DNS switch, and a failover drill that replays the reachability matrix on the second site.

## 7. Isolation on the `svc_public` plane

**Choice.** Backends of several tenants are published on the shared `svc_public` plane; security groups admit only the edge.

**Why.** One plane serves every tenant: no per-tenant network between the edge and each backend.

**Cost.** At the network level, every project attached to `svc_public` can reach every backend published on it. Isolation rests on security groups alone, without defence in depth. The rules must match the address the backend actually sees: the edge floating IPs on `svc_public`, or the edge router gateway address when the edge reaches the plane through SNAT. A mistake in one rule exposes a backend to every tenant on the plane.

**Alternative.** A dedicated transit network between the edge and each tenant.

**Choose it when** the tenants do not trust each other: it adds a network and a router per tenant, but a wrong security group rule no longer opens a path.

## 8. Tenant-owned security groups or a central catalogue

**Choice.** Each tenant declares its own security groups. A central catalogue shared by RBAC is an operator option of layer 10.

**Why.** It works on any cloud, with one project or many, and needs no admin rights. Rules between tenants use CIDRs because `remote_group_id` only works inside one project.

**Cost.** Common rules (SSH from an administration network, metrics scraping) are repeated in every tenant and can drift.

**Alternative.** A central catalogue of security groups owned by the operator and shared with the projects by RBAC.

**Choose it when** one team governs the network rules of every tenant and wants a single place to change them.

## 9. Kubernetes with Cluster API

**Choice.** Terraform prepares the project; Cluster API Provider OpenStack creates and maintains the clusters.

**Why.** Cluster API handles the lifecycle Terraform handles badly: rolling upgrades, node replacement, scaling. It needs only project-level rights.

**Cost.** Two tools and two states: Terraform for the infrastructure, Cluster API objects for the clusters. Node images must be built and kept current with image-builder. This reference makes the cluster **self-managed** (`clusterctl move`): no management cluster to run, but a broken cluster cannot repair itself; the repair path is to move Cluster API back to a temporary kind cluster (what `delete-cluster.sh` does). The glue between Terraform and Cluster API is a shell script on a bootstrap instance, and the cluster credential is created by the operator, outside Terraform, so that no secret is in the state.

**Choose a dedicated management cluster when** you run several clusters: it manages them all and survives the loss of any one.

**Alternative.** A managed Kubernetes service (Magnum or the cloud's own offer).

**Choose it when** your cloud offers one and its versions and options suit you: you give up control for less to operate.

## 10. Layer 10 provided by the operator

**Choice.** Until cloud-baseline (module v0.2), the shared planes are created by the operator and adopted by name.

**Why.** It matches the primary audience, who consume a cloud they do not administer, and it lets layers 20 and 30 exist before cloud-baseline.

**Cost.** The repository cannot build its own prerequisites: the [layer 10 contract](architecture.md#layer-10-contract) must be met by hand.

**Next.** cloud-baseline adds `stacks/10-shared-planes` without changing layers 20 and 30.

## 11. One network for administration and intranet

**Choice.** Administration (bastions, Kubernetes API) and intranet (internal services) are two roles. One network may carry both, provided the administration endpoints admit **specific operator addresses**, never the network range.

**Why.** Many clouds have a single internal network. A tenant joining the intranet appears there with an address of its range (source NAT): admitting the range would let any workload of that tenant reach every bastion and API.

**Cost.** Operator addresses must be known and kept current, and they are often router addresses, easy to guess wrong (see [testing.md](testing.md)).

**Choose two networks when** you can: the administration network then admits nobody but operators by construction.

## 12. Add-ons declared with Cluster API, not GitOps

**Choice.** Cluster API Add-on Provider Helm (CAAPH) installs the add-ons, declared next to the cluster and moved with it.

**Why.** One tool and one set of objects for the cluster and its add-ons; nothing more to install.

**Cost.** CAAPH does not correct drift: a manual change to an add-on stays until the chart values change. Release names must be fixed, or a new reconciliation installs a chart twice.

**Choose GitOps (Flux or Argo CD) when** several people change the clusters: drift becomes visible and reverted.

## 13. Kubelet serving certificates from the cluster CA

**Choice.** Kubelets request serving certificates from the cluster CA (`rotate-server-certificates`); kubelet-csr-approver approves them for this cluster's node names and addresses only; metrics-server verifies them.

**Why.** The common shortcut, metrics-server with `--kubelet-insecure-tls`, accepts any certificate presented by anything that answers on the kubelet port.

**Cost.** One more controller, and a policy (node name pattern, address range) to keep in line with the cluster.

## 14. Node image size

**Choice.** The node image is built on a small volume (8 GiB); the root disk of each node is chosen by the cluster, per role.

**Why.** The virtual size of the image is the minimum disk of every node. A 20 GiB image forced 20 GiB per node, test clusters included.

**Cost.** None at run time: cloud-init grows the root partition to the disk each machine gets.

## Evidence

The architecture is tested on a real cloud, with the findings that shaped several choices above: [testing.md](testing.md).


The module this architecture builds on is tested on a real cloud: apply, empty plan after apply, destroy. Results are in the module's [testing report](https://github.com/CyprisTech/terraform-openstack-tenant/blob/main/docs/testing.md).
