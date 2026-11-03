# Planes contract

What the stacks expect from planes **provided by the cloud operator** as external networks ([ADR-0004](../adr/0004-planes-and-isolation.md), D1). Planes you build yourself, with a member role, in a hub project are created by [`stacks/shared/planes`](../../stacks/shared/planes/README.md), which meets this contract itself.

`shared/planes` adopts the cloud operator's planes by name and describes them to every other stack (`plane_attachment`): the other stacks never look them up.

| Object | Requirement |
|---|---|
| A network per plane declared in `shared/planes` (in the scenario `svc_public`, `monitoring`, `intranet`) | External networks visible to the projects that join them, each with one subnet usable as a router gateway; joined with source NAT (the default) or, in a shared address scope, routed (with cloud-baseline) |
| Plane ranges | The range reached through each plane (`cidr` in `shared/planes`), advertised by DHCP in the tenant subnets |
| MTU | The MTU of each plane, and the largest MTU the cloud carries for tenant networks (lower when the tenant overlay itself runs over a tunnel). Tenant networks that join a plane use the smallest of these values (`network_mtu`): OVN routers do not send "fragmentation needed" by default, so a larger MTU silently drops large packets |
| Floating IPs | On the planes where something must be reached at a stable address — in the scenario, the tenants' service addresses on `svc_public` and the receiver on `monitoring` — one per address |
| Reserved ranges | The ranges tenants must not use for their networks (ranges used by the cloud infrastructure) |
| Public network | A network providing floating IPs reachable from the Internet, for the entry point load balancer (and the tenants exposed with `exposure = "public"`) |
| Administration network and sources | An external network for the bastions and the Kubernetes API floating IPs, and the **administrator addresses** allowed on them. Recommended: a network distinct from the intranet. With one network for both roles, the administration sources must be specific addresses, never the network range ([ADR-0005](../adr/0005-stacks-contracts-and-access.md), D5) |
| Octavia | Available to the projects (amphora provider) |
| Image | An Ubuntu LTS cloud image visible to the projects |
| Flavors and quotas | At least the [sizing](../concepts/architecture.md#sizing), per project |
| DNS | A zone per project for the public records and the tenants' ACME DNS-01 challenges (optional, Designate) |

Security groups are declared by each tenant. A central catalogue shared by RBAC is an operator option that comes with cloud-baseline.
