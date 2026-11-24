# Spec: segments provided by the operator

- **Status:** Proposed, for `v0.7`
- **Related:** [ADR-0004](../adr/0004-planes-and-isolation.md) (planes and isolation), [ADR-0013](../adr/0013-plane-routes-on-a-transit-router.md) (transit router), [ADR-0006](../adr/0006-exposure.md) (exposure), [ADR-0016](../adr/0016-network-services-and-edge-by-level.md) (egress), [How a tenant joins a plane](../concepts/plane-attachment.md), [planes contract](../reference/planes-contract.md), [trade-offs, 7](../concepts/trade-offs.md#7-isolation-on-the-publication-plane)

## Problem

Many private OpenStack clouds, in companies and at network operators, do not let projects build their own network. The operator gives each project a **segment**: a provider network (often a VLAN) with its subnet, whose gateway is the operator's router or firewall, outside the project. Projects have no router of their own, or no right to create one. Traffic between projects, to shared services and to the Internet goes through that gateway: the path is forced by the topology, and the operator's firewall decides what passes.

The reference cannot be deployed on such a cloud. Every tenant stack creates its network and its routers: one router per plane, a transit router holding the subnet's gateway ([ADR-0013](../adr/0013-plane-routes-on-a-transit-router.md)), an egress or public router. The two kinds of planes of [ADR-0004](../adr/0004-planes-and-isolation.md) both assume a router in the tenant's project.

This is not the design set aside in [How a tenant joins a plane](../concepts/plane-attachment.md#the-alternative-not-used-ports-of-the-instances-on-the-planes): there, instances get one port per plane on networks shared by every tenant. Here, each project keeps a single segment of its own, and the planes are destinations reached through the operator's gateway.

## Goal

The same stacks deploy on a cloud that gives each project a segment:

- each tenant and each project of shared services **adopts the segment it is given** and creates no router;
- the planes (publication, observability, internal services) are **ranges reached through the segment's gateway**, routed by the operator;
- isolation between projects is **enforced by the operator's topology and firewall**; the security groups of every target stay, as a second line ([ADR-0004](../adr/0004-planes-and-isolation.md), D4);
- the isolation test runs unchanged and becomes an **independent check of what the operator's firewall lets through**.

Out of scope: configuring the operator's firewall or routers (level 1, [ADR-0003](../adr/0003-scope-and-boundary.md)); creating the segments, which needs administrator rights; a firewall run by the reference.

## What the reference brings on this kind of cloud

The network isolation belongs to the operator. What the reference adds is everything above it, the same as on the other clouds:

| Design area | On a cloud of segments |
|---|---|
| Publication | The shared entry point routing by SNI to each tenant's service address, without decrypting; domains published without interruption. The operator routes the publication range between the entry point's segment and the tenants' segments, and gives the entry point its public address. |
| Observability | Agents pushing to the receivers through the operator's routing; nothing connects into a project ([ADR-0007](../adr/0007-monitoring.md)). |
| Certificates | Each tenant obtains its own, by ACME DNS-01 ([ADR-0008](../adr/0008-tenant-certificates.md)). |
| Kubernetes | Clusters created by Cluster API on the tenant's segment. |
| Administration | Bastions, when the operator routes the administrators' addresses to the segments. |
| Proof of isolation | The isolation test, run from every project: a check of the operator's rules that does not rely on reading them. |
| Organisation | One project per role, contracts between stacks, environments, upgrades between releases. |

## Design

1. **A third kind of plane: `mode = "segment"`.** `shared/planes` describes each plane as a range reached through the segments' gateway, with no network or router to join. `nat` keeps its meaning: whether the operator's gateway translates the addresses between segments (then the target sees the gateway's address) or routes them. Planes of different kinds are not mixed with `segment` in one deployment: a project either has routers or does not.
2. **Each attachment names its segment.** For each project, `shared/planes` adopts by name the segment the operator gave it (network and subnet), checks that its range overlaps neither the planes nor the other segments, and passes it in `plane_attachment`. The other stacks never look it up ([ADR-0005](../adr/0005-stacks-contracts-and-access.md)).
3. **Tenant stacks adopt the segment.** `vm` (and the private tenant of [ADR-0016](../adr/0016-network-services-and-edge-by-level.md)) and `kubernetes` take the segment from `plane_attachment` as an existing network: no network, subnet or router is created, no transit router, no host route. Instances have one interface, and their default route is the operator's gateway. The tenant module (terraform-openstack-tenant `v0.1.6`) already places instances and load balancers on the networks given in `existing.networks` and creates no router when none is declared: in this mode the stacks declare none.
4. **Service addresses.** A tenant's service address is its load balancer's address on its segment. Load balancers on a segment work as on any provider network: the VIP and the members are on the segment, and the load balancer's default route is the subnet's gateway, the operator's; there are no host routes, so the issue that led to [ADR-0013](../adr/0013-plane-routes-on-a-transit-router.md) does not arise. The entry point reaches it through the operator's routing; `edge_sources` is the entry point's address as the tenant sees it: its own, or the gateway's when the operator translates (output `publication_sources`, as today).
5. **Exposure and egress.** `exposure = "public"` needs a public address on the tenant: on a cloud of segments, a destination translation (static NAT) on the operator's gateway, from a public address to the tenant's service address, configured by the operator outside the stacks. The stack outputs the address to translate and takes the public address as an input, which it publishes in the domain's DNS records (`published_domains` unchanged). `egress` is the operator's: `router` has no meaning and is refused with `mode = "segment"`; `none` and `shared` keep theirs.
6. **The entry point** adopts its own segment. Its public address is either a floating IP of an external network the operator gives that project, or a translation on the operator's gateway (an output of the stack, as in part 5).
7. **Kubernetes.** The cluster uses the tenant's segment as an existing network: Cluster API creates no network and no router, and its API load balancer has an address on the segment, reached by the administrators through the operator's routing. Cluster API Provider OpenStack supports this case (an existing network and subnet, no router, no external network); the cluster's floating IPs are disabled.
8. **Fixtures.** The receiver, the internal service and the ACME fixture adopt segments like any shared service.
9. **Test on the [DevStack bench](https://github.com/CyprisTech/terraform-openstack-cloud-baseline/blob/main/docs/specs/devstack-test-bench.md) of `cloud-baseline`, with administrator rights**, like the routed operator planes. The bench has what a classic private cloud has and our test cloud does not give us: real segments. It plays the outside of each operator plane with a network namespace; the segments follow the same design: one more physical network, `segments`, of type VLAN, on its own bridge, and the operator's gateway played by a namespace that routes and filters between the VLANs and towards the planes' namespaces. `cloud-baseline` `v0.1` already creates provider networks with a physical network, a type and a segmentation ID, shared with one project by RBAC: one segment per project, owned by the operator, so that the project cannot change its gateway, its addressing or its DHCP; a segment owned by the project, the other common practice, is adopted the same way. The bench gains the VLAN type and its range in `local.conf` and the segments in `planes.sh`. The campaign runs the stacks with `mode = "segment"`, the isolation test from every project, and checks that a tenant cannot reach another project's segment by any means its member role gives it. Kubernetes is out of the bench, as its spec sets it (too heavy for nested virtualization): the adoption of an existing network with no router created by the stack (Cluster API on an existing network, the cloud controller manager's load balancers on it, administration through the gateway) is tested in the usual campaign on the test cloud, where a fixture makes the network and its gateway; Kubernetes on real segments is documented, not tested.

## Why several planes

The reference keeps one plane per purpose: what does not join a plane has no path to it (a private tenant has no route to the publication plane; the entry point and the receiver none to the internal services), and each plane has its own shared services and admission rules ([architecture](../concepts/architecture.md#topology)). On a cloud of segments, the operator's firewall keeps the planes apart: for each plane, it lets through only the roles of [ADR-0004](../adr/0004-planes-and-isolation.md) D2, from the tenants to the plane's shared services and from those services to the tenants, never from one tenant to another, and it gives a segment no path to a plane the project does not join. The planes contract states it, and the isolation test checks it. On routed operator planes, delivered with this mode, the operator's routing domains do the same: without them, the tenants of one address scope reach each other at layer 3, and only the security groups keep them apart.

## Dependencies and order

Depends on the egress and exposure inputs of the [network services spec](network-services.md) (`exposure = "none"`, `egress`), and on the bench's step 2, with `cloud-baseline` `v0.2`. The reference does not depend on `cloud-baseline` in its code: it adopts the segments by name, whoever creates them (`cloud-baseline`, the operator's own tooling or by hand); `cloud-baseline` is how the bench creates them. Delivered in `v0.7` with the routed operator planes: same profile (`private-cloud`, [ADR-0014](../adr/0014-profiles.md)), same bench, same dependency.

0. **The bench carries the reference first.** The reference has never run on the bench, and `cloud-baseline` has never fed it. The bench's step 2 does that before anything new: Octavia, then the reference in gateway mode on the operator planes created by `cloud-baseline` (VM tenants, isolation test), with `cloud-baseline` `v0.2` (Octavia's objects). A failure of the new mode is then not mixed with a failure of the bench or of the contract between the two repositories.
1. `shared/planes`: the `segment` kind, the adoption of segments, the checks of ranges; the planes contract gains a section for segments.
2. `vm` and the private tenant on an adopted segment; the operator's gateway as a test fixture on the bench; isolation test.
3. Entry point and publication on segments, with and without translation by the gateway.
4. `kubernetes` and the shared cluster on segments.
5. Campaign profile on segments; documentation (architecture, plane attachment, audiences: the operator of a classic private cloud and its users).

## Proposed decisions

These become an amendment of [ADR-0014](../adr/0014-profiles.md) (D1: `segment` in the planes of the `private-cloud` profile), of [ADR-0004](../adr/0004-planes-and-isolation.md) (D1: a third kind of plane; D4: isolation enforced by the operator, the security groups as a second line) and of [ADR-0013](../adr/0013-plane-routes-on-a-transit-router.md) (no transit router when the operator holds the gateway) when the work starts.

- **The tenant adopts the segment and creates no router.** Set aside: a tenant router on the segment, which most such clouds do not allow, and which would give the tenant a way around the operator's path.
- **The planes are ranges routed by the operator, not networks.** Set aside: ports of the instances on shared plane networks ([How a tenant joins a plane](../concepts/plane-attachment.md#the-alternative-not-used-ports-of-the-instances-on-the-planes)), which removes the boundary that segments give.
- **Security groups stay at every target.** A wrong rule on the operator's firewall should not open a tenant by itself.
