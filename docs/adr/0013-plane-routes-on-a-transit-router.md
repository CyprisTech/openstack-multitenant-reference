# ADR-0013: Plane routes on a transit router

- **Status:** Proposed
- **Date:** 2026-11-18
- **Deciders:** maintainers
- **Refines:** [ADR-0001](0001-reference-architecture.md) D2 (the routes to each plane are advertised by DHCP); [ADR-0004](0004-planes-and-isolation.md) D1 (how a tenant router joins a plane)

## Context

A tenant reaches each plane through that plane's router. Until this decision, the instances learned the route to each plane from their subnet: one host route per plane, pushed by DHCP, whose next hop is the plane router's address on the subnet. One of the routers, the egress router or a plane's router for a tenant with no egress, held the subnet's gateway address.

Host routes are not read again at the same moment by everyone:

- instances and Kubernetes nodes read them at boot and at each DHCP renewal;
- Octavia load balancers of the amphora provider copy them once, when their VIP is plugged, and never read them again.

The test campaign showed the consequence. After an exposure change ([ADR-0006](0006-exposure.md)), the publication router's interface came back with a new address; the existing load balancers kept the old next hop, sent ARP requests for an address that no longer existed and answered no client of the plane. The load balancer stayed ACTIVE and ONLINE: its health checks reach the members, on its own subnet.

Every day-2 change of a running tenant's routes has the same effect: a plane joined later (internal services, monitoring, publication), a plane created by the operator, a site whose ranges are not covered by an existing destination, a plane router replaced by an apply.

## Options considered

1. **Keep host routes; refresh the load balancers after each route change** (failover or recreation). Silent failures until someone refreshes them; a failover is an admin operation on most clouds; the Kubernetes cloud controller manager does not do it for the load balancers it creates.
2. **Keep the plane router's port across exposure changes**, so that its address does not change. Covers a new next hop, not a new destination.
3. **Fixed addresses for the plane routers** in the configuration. Same coverage as 2, and removes the dynamic allocation.
4. **One gateway per subnet, the routes to the planes on it** (chosen).

## Decision

### D1 — A transit router, gateway of the subnet

Every tenant subnet gets a **transit router**: a router with no external gateway, holding the subnet's gateway address. The instances get one route only, the default route to the transit router. The subnet carries no host routes.

The transit router holds a static route (Neutron extra route) to each plane's range, and to every range routed through an interface plane, whose next hop is the plane router's address on the subnet; the stack's own destinations (the administration network of a Kubernetes cluster) likewise. A route change is a change of the transit router: it applies at once, for every source of the subnet, load balancers included.

### D2 — Next hops named by router

The next hop of each route is the address Neutron allocates to the plane router on the subnet, named by router key (`next_hop_router`, terraform-openstack-tenant v0.1.6). No address is chosen in the configuration.

### D3 — The default route goes to the default router

The default route (`0.0.0.0/0`) of the transit router goes to the stack's default router: its egress router (`vm`, `kubernetes`, the fixtures), its public router (entry point), or, for a tenant with no egress, a plane's router (`isolated`: observability; it reaches its resolvers that way). Without a default router, unknown destinations are dropped at the transit router.

The transit router does not filter: routes are not a security boundary ([ADR-0004](0004-planes-and-isolation.md)). The security groups at each target decide, as before.

## Consequences

- **Every route change reaches every consumer at once**, without a failover and without waiting for DHCP. The exposure change of a running tenant, between the entry point and direct exposure ([ADR-0006](0006-exposure.md)), works in both directions (test campaign of 2026-11-18, both plane modes).
- **One router more per tenant**: plan the router quotas of the projects (the test project of the shared services, with three stacks, reached its default quota of 10).
- **One hop more** on every outbound flow: transit router, then plane or egress router, in OVN's distributed pipeline. Inbound flows are unchanged; the reply leaves through the transit router and comes back to the router that translated it.
- **Migration of a running tenant**: the apply removes the subnet's host routes and adds the transit router. Load balancers keep their copied host routes, whose next hops (the plane routers) still exist; instances use the default route at their next DHCP renewal. The gateway address moves from the egress router to the transit router: the egress router's port is replaced, and outbound traffic to the Internet stops while it is. The campaigns build every stack from empty projects: the migration of a running tenant is not tested yet.
- **Projects joined with other tools** ([Connect](../guides/existing-projects.md)) put the routes to the planes on the router holding their subnet's gateway, not in host routes.
