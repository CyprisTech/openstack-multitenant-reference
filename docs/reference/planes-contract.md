# Planes contract

What the stacks expect from the shared planes, whoever provides them: the operator of a private cloud, or the account holder with shared private networks ([ADR-0003](../adr/0003-scope-and-plane-provisioning.md)).

Whoever provides the planes — the cloud operator, or the account holder with shared private networks (in progress, ADR-0003) — supplies the following objects; the stacks find them by name.

| Object | Requirement |
|---|---|
| Networks `svc_public`, `intranet`, `monitoring` | Visible to the tenant projects (shared or external), each with one subnet usable as a router gateway |
| Plane routes | The CIDR of each plane, to be advertised by DHCP in the tenant subnets |
| MTU | The MTU of each plane, and the largest MTU the cloud carries for tenant networks (lower when the tenant overlay itself runs over a tunnel). Tenant networks that join a plane use the smallest of these values (`network_mtu`): OVN routers do not send "fragmentation needed" by default, so a larger MTU silently drops large packets |
| Monitoring zone | A DNS zone shared with the tenant projects, where each stack writes the A records of its instances (collector service discovery) |
| Collector | A collector with an address in the `monitoring` range, outgoing TCP to the metrics ports, and its addresses published (`monitoring.collector_cidrs` of the stacks) |
| Reserved ranges | The ranges tenants must not use for their networks (ranges used by the cloud infrastructure) |
| Public network | A network providing floating IPs reachable from the internet, for the edge load balancer |
| Administration network and sources | An external network for the bastions and the Kubernetes API floating IPs, and the **operator addresses** allowed on them. Recommended: a network distinct from the intranet. With one network for both roles, the administration sources must be specific addresses, never the network range: tenants joining the intranet reach it with addresses of its range ([ADR-0002](../adr/0002-platform-kubernetes.md), D6) |
| Octavia | Available to the projects, with a load balancer flavor (amphora topology) |
| Image | An Ubuntu LTS cloud image visible to the projects |
| Flavors | Sizes listed in the sizing table below |
| DNS | A zone per project, or a shared zone where projects may write records (optional, Designate) |
| Quotas | At least the sizing table below, per project |

Security groups are declared by each tenant. A central catalogue shared by RBAC is an operator option that comes with cloud-baseline.
