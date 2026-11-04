# ADR-0004: Shared planes and isolation between tenants

- **Status:** Accepted (implemented in v0.3.0)
- **Date:** 2026-11-02 (from ADR-0003 D2 of 2026-10-30, revised after the reviews of 2026-10-31)
- **Deciders:** maintainers
- **Refines:** [ADR-0001](0001-reference-architecture.md) D2 (planes provided by the operator only) and D7 (security groups)

## Context

Tenants reach the shared services through **planes**, any number, each with its own purpose; in the reference scenario, `svc_public` for publication, `monitoring` for observability, `intranet` for internal services. In `v0.2.x` every plane is an external network of the cloud operator, joined by each tenant router through its gateway with source NAT. On a public cloud, a member of the projects cannot create external networks: the architecture could not be deployed there.

OpenStack has no native peering or transit gateway between projects. With a member role, sharing a network by RBAC and static routes are the only means; with admin rights, address scopes route projects without translation. The closest published design is OVHcloud's hub-and-spoke landing zone (a transit network and a firewall at the hub, with static routes to each spoke).

How a tenant joins a plane is detailed with diagrams in [How a tenant joins a plane](../concepts/plane-attachment.md).

## Options considered

1. **Planes as operator external networks only.** Excludes every public cloud.
2. **Ports of the instances directly on the planes** (provider networks, OVHcloud vRack). Real addresses without routers, but no network boundary per tenant, isolation by security groups and anti-spoofing only, and several interfaces per instance to manage. Not used; to reconsider on demand, for tenants that trust each other.
3. **A firewall instance at the hub instead of a Neutron transit router**, as OVHcloud does. Central filtering, but one more component to run in high availability, and the security groups remain needed at each target. A variant: the next hop of the routes can be a firewall instead of the transit router without changing the tenants.
4. **Planes described by two independent properties, provided by the operator or built in a hub project** (chosen).

## Decision

### D1 — A plane is described by two properties

| | How the tenant router joins it | Are addresses translated |
|---|---|---|
| `mode` | `gateway`: its gateway port, on an external network · `interface`: an interface port, on a shared network | |
| `nat` | | `true`: source NAT, a floating IP when an address must be identifiable · `false`: routed, the tenant is seen at its real address |

Three cases follow:

| The plane is | `mode` | `nat` | Fits when |
|---|---|---|---|
| an external network of the operator | `gateway` | `true` | tenants keep their own ranges, which may overlap, and the operator has no dynamic routing towards them |
| an external network of the operator in a shared address scope | `gateway` | `false` | the operator coordinates the addressing and advertises the tenant ranges (BGP) |
| a network of a hub project shared by RBAC | `interface` | `false` | member role only (public cloud), or an operator that prefers it |

- **The stack `shared/planes` is the single description of the planes**, adopted from the operator or built in the hub. Every other stack takes its `plane_attachment` from it and does not depend on where the planes come from ([ADR-0005](0005-stacks-contracts-and-access.md)). Planes of different cases can be mixed in one deployment.
- With `nat = true`, an instance or a load balancer has **at most one floating IP** ([ADR-0006](0006-exposure.md), D4).

### D2 — Hub and transit router (`interface` planes)

- The hub project creates each plane, shares it with the attached projects (`access_as_shared`) and holds a **transit router at the plane's first address**, its gateway. A project cannot choose its address on a network it does not own (Neutron policy `create_port:fixed_ips:ip_address`): the attached routers take an address from Neutron, the transit router is the only fixed address on the plane.
- **Roles per plane.** Each attachment declares, on each plane it joins, the role `shared` (it provides a service to the plane: in the scenario, the entry point on `svc_public`, a receiver on `monitoring`) or `tenant`. A tenant routes to the shared services of the plane; a shared service routes to the other shared services and to the tenants, through aggregates of their ranges when given. All routes go through the transit router and are known before the attachment exists. **Never between two tenants.**
- **Discovery.** The plane's owner sees every port on it: at each apply, `shared/planes` finds the address of each attached router, identified by its subnet range, and routes the attachment's range to it. OpenStack has no route propagation between projects: this apply is where it happens.
- **Limits**, documented: `max_routes` (30 by default) caps a transit router at about 30 attachments per plane; network sharing by members may be forbidden by the cloud (the Sovereign Cloud Stack draft standard scs-0126 recommends it), and the providers limit the projects and RBAC policies of each customer. The getting started checks them before the first apply.

### D3 — Addressing and MTU

- **Ranges.** On an `interface` plane, the ranges of the attachments must not overlap each other or the planes; `shared/planes` checks it. On a `gateway` plane with NAT, tenant ranges may overlap. The ranges reserved by the operator and the aggregates of tenant ranges are part of the [planes contract](../reference/planes-contract.md).
- **MTU.** Every network on a path is given an explicit MTU no larger than the smallest MTU of the path: the tenant networks take the planes' MTU minus the encapsulation of the cloud. OVN does not send "fragmentation needed" across routers, so a larger tenant MTU is a silent black hole (seen on the reference cloud: tenant networks at 1362 behind planes at 1382). The Kubernetes network plugin takes the cluster network MTU minus its own encapsulation (ADR-0002).

### D4 — Security model

- **What a tenant can do with a member role**: anything in its project, including adding routes on its own routers towards any range, and sending any traffic its security groups allow on the planes it joins.
- **What isolates tenants**: the **security groups of every target**, which admit only named sources — the entry point, the administrators' addresses, the consumers of an internal service. Each tenant declares its own security groups; rules that name another project use address ranges, never `remote_group_id`, which only works inside one project.
- **Routes are not a security boundary**: a tenant controls its own router. The isolation test includes a tenant routing to another through the transit router and still reaching none of its ports.
- **Layer 2 on a shared plane**: tenants on one shared network rely on Neutron's port security (anti-spoofing) against address and ARP spoofing; port security stays enabled on every port.
- **Credentials**: one per stack, scoped to one project ([ADR-0005](0005-stacks-contracts-and-access.md)). The hub's credentials see every port on the planes and are kept for `shared/planes` only.
- A central security group catalogue shared by RBAC remains an operator option of cloud-baseline (ADR-0001, D7).

### D5 — Several regions

- Each region has its own planes, hub and transit routers: Neutron networks do not cross regions.
- The hubs of the regions are joined by an encrypted overlay, so that the shared services and tenants of one region reach those of another through the planes, with the same roles: the routes between regions follow from the roles, as within a region.
- Each region has its own entry point; failover between regions is a DNS change (active/passive).
- The overlay, its addressing and its routing are specified when this decision is implemented.

## Consequences

- One stack, `shared/planes`, holds all the variation between clouds; the other stacks are the same everywhere.
- Adding a tenant on an `interface` plane: apply `shared/planes` (RBAC), the tenant's stack, then `shared/planes` again (route on the transit router). No shared service changes when the tenant's range is inside the aggregates.
- Settled on the reference cloud (2026-10-31, one project per stack, both implemented cases, isolation test 45/45 each): a member can share a network by RBAC; a project cannot choose its address on a shared network it does not own; the plane's owner sees every port on it; OVN routes a packet back out of the interface it came in (transit router); Octavia members behind the shared plane work; MTU as in D3.
- Still open, to check on a public cloud: the same policies, and the limits of projects and RBAC policies per customer of the provider.
