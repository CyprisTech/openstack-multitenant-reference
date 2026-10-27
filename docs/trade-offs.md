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

**Choice.** Octavia adds a PROXY header towards Traefik; Traefik sends PROXY protocol v2 to the backends.

**Why.** Without it, every backend sees the edge address as the client. Logs, rate limits and allow lists on the backends need the real client address, and TLS passthrough leaves no `X-Forwarded-For` header to carry it.

**Cost.** Every hop must agree. A backend that does not expect the header fails every connection, and a backend that accepts it from untrusted sources lets clients forge their address. Traefik only trusts the header from the load balancer subnet (`trustedIPs`), and each backend must do the same with the edge addresses.

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

**Cost.** Two tools and two states: Terraform for the infrastructure, Cluster API objects for the clusters. A management cluster must exist and be backed up (or the CAPO resources moved into the workload cluster), and node images must be built and kept current with image-builder.

**Alternative.** A managed Kubernetes service (Magnum or the cloud's own offer).

**Choose it when** your cloud offers one and its versions and options suit you: you give up control for less to operate.

## 10. Layer 10 provided by the operator

**Choice.** Until cloud-baseline (module v0.2), the shared planes are created by the operator and adopted by name.

**Why.** It matches the primary audience, who consume a cloud they do not administer, and it lets layers 20 and 30 exist before cloud-baseline.

**Cost.** The repository cannot build its own prerequisites: the [layer 10 contract](architecture.md#layer-10-contract) must be met by hand.

**Next.** cloud-baseline adds `stacks/10-shared-planes` without changing layers 20 and 30.

## Evidence

The module this architecture builds on is tested on a real cloud: apply, empty plan after apply, destroy. Results are in the module's [testing report](https://github.com/CyprisTech/terraform-openstack-tenant/blob/main/docs/testing.md).
