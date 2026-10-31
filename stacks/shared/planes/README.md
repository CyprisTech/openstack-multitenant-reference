# Stack `shared/planes`

The shared planes ([ADR-0003](../../../docs/adr/0003-scope-and-plane-provisioning.md), D2; [How a tenant joins a plane](../../../docs/concepts/plane-attachment.md)). The single source of the planes' description for every other stack, whatever provides the planes. Applied before the other stacks and again after an attachment joins or leaves: with the credentials of the **hub** project when it builds planes, of any project (the shared services') when it only adopts the operator's. The hub project holds the network only: the planes, their RBAC policies and their transit routers. Shared services (entry point, collector, internal services) run in their own projects, attached with the role `shared`.

| Plane mode | What this stack does | How an attached router joins |
|---|---|---|
| `gateway` | Adopts the operator's external network by name; creates nothing | Its gateway (source NAT, floating IPs) |
| `interface` | Creates a private network in the hub project (no DHCP), shares it with every attached project by RBAC (`access_as_shared`), and creates a **transit router** on it at the plane's first address, its gateway | An interface (address given by Neutron) and routes through the transit router |

## The transit router

On an interface plane, attached routers never route to each other directly: every route goes through the transit router, the hub-and-spoke a transit gateway provides on other clouds.

- **Roles are per plane.** Each attachment declares its role on every plane it joins: `shared` (the entry point on `svc_public`, the collector on `monitoring`, an internal service on `intranet`) or `tenant` (a workload, or a target: the entry point is a monitored target on `monitoring`).
- **Routes of the attached routers** (output `attachments.<name>.planes.<plane>.routes`), known before the attachment exists: a tenant reaches the shared services of the plane; a shared service reaches the other shared services and the tenants of the plane — through the plane's `tenant_ranges` aggregates when given.
- **Routes of the transit router**: one per attachment already joined, to the address Neutron gave its router on the plane. The hub owns the plane, so it sees every port on it: this stack discovers the addresses itself, at every plan ([`modules/plane-discovery`](../../../modules/plane-discovery/README.md)).

A project cannot choose its own address on a network it does not own (Neutron policy `create_port:fixed_ips:ip_address`); the hub can, which is why the only fixed address is the transit router's.

## Adding, changing, removing an attachment

1. Add the entry here and apply: the RBAC policies are created.
2. Apply the attachment's stack with its `attachments.<name>.planes` (stacks read it through [`modules/plane-attachment`](../../../modules/plane-attachment/README.md)): its router joins the plane, with its routes through the transit router.
3. Apply this stack again: it discovers the new router's address and adds the route on the transit router.

With `tenant_ranges` covering the new tenant, no shared service is applied again. Removing goes the other way: destroy the attachment's stack, apply this stack (the route goes away), then remove the entry and apply (Neutron refuses to remove an RBAC policy while a port of the project is still on the plane).

If an attachment's router is recreated, its address changes: apply this stack again; traffic to that attachment is cut until then.

To rename an attachment, remove it and apply, then add it under its new name and apply: in a single apply, the new RBAC policy may be created before the old one is deleted, and Neutron refuses two identical policies (`DuplicateRbacPolicy`; a second apply completes the change).

## Checks and limits

- The hub project is not an attachment: it holds the network only.
- Planes do not overlap each other nor any attachment ([`modules/range-overlaps`](../../../modules/range-overlaps/README.md)); attachments sharing an interface plane do not overlap (on gateway planes they may, being never seen); every plane of an attachment is declared; an attachment has a single router interface on a plane.

The plane and its transit router are created with the network module of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant).
- Neutron caps the routes of a router (`max_routes`, 30 by default): the transit router of a plane routes to about 30 attachments.
- Discovery relies on the default Neutron policy that lets a network's owner read the ports on it; check it on each cloud.
