# ADR-0003: Scope — one account, one project per tenant; how the planes are provided

- **Status:** Proposed
- **Date:** 2026-10-30
- **Deciders:** Gregory Gabrielian
- **Refines:** [ADR-0001](0001-reference-architecture.md), D1 and D2 (planes can be provided without the operator; repository layout), and [ADR-0002](0002-platform-kubernetes.md) (Kubernetes as a tenant type); supersedes the draft [plane bindings specification](../specs/plane-bindings.md)

## Context

The reviews of 2026-10-29 and 2026-10-30 found three gaps between what the repository says and what it does:

1. **Scope.** The README addressed teams consuming a public cloud with a single application. That case is served by [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) and its examples. What this repository adds is the case its name describes: **several tenants, one project each, in one OpenStack account, sharing services**.
2. **Who provides the planes.** The planes (`svc_public`, `monitoring`, `intranet`) are external networks provided by the cloud operator. On a public cloud, the account holder cannot create external networks: the architecture could not be deployed there.
3. **Emphasis.** Readers first want to know what they get and how to run it; the isolation test is most useful as an operating tool (run it after every change) and as material for customers and auditors, not as the headline.

## Options considered

1. **Keep the planes as external networks only.** Simple, but excludes every public cloud.
2. **Add a single-project or one-application mode.** Duplicates the module's examples and blurs the scope.
3. **Keep the scope to one account with one project per tenant, and provide the planes in two ways** (chosen).

## Decision

### D1 — Scope

- **One OpenStack account, projects by role.** Each tenant has its own project, credentials and quotas. Shared services (the entry point, a collector, internal services) run in projects of their own, never in the hub project nor with tenant workloads; one such project may host several of them, for example on a Kubernetes cluster ([spec](../specs/kubernetes-shared-services.md)). The shared planes play, inside one account, the role a transit gateway plays between networks on other clouds: a hub-and-spoke that OpenStack does not offer natively.
- **The hub project holds the network only**: the shared private planes, their RBAC policies and their transit routers. No instance, no shared service: its credentials share the planes and see every port on them, so nothing else should run with them.
- **Regions.** A stack works in one region, the one of its `clouds.yaml` entry. A site (ADR-0001, D9) is one region: several regions are several deployments of the stacks, each with its own entries.
- **Keystone domains.** The stacks use credentials scoped to one project; the domain only appears in the authentication (`user_domain`, `project_domain`). Sharing between projects (Neutron RBAC, Designate zone sharing) uses project IDs; whether a cloud allows it between projects of different domains depends on its policy, to check on each cloud.
- Out of scope, with a pointer in the README:
  - a single tenant or application → the module and its examples;
  - tenants in several accounts or clouds → shared planes do not cross accounts; each account is managed with the module, and an encrypted overlay between accounts is a later direction;
  - an operated, production-ready platform → projects such as Sovereign Cloud Stack or Azimuth; this repository is a reference with a production checklist.
- Projects are created by the account holder (the provider's console or API, or cloud-baseline on a private cloud). The stacks consume existing projects; the documentation says how to obtain them on the tested clouds, and warns about the project limit of each provider.

### D2 — How the planes are provided, and how a tenant joins them

The details, with diagrams, are in [How a tenant joins a plane](../concepts/plane-attachment.md).

| | **Operator planes** (private or sovereign cloud) | **Shared private planes** (public cloud) |
|---|---|---|
| A plane is | an external network created by the cloud operator | a private network of the hub project, shared with the attached projects (tenants and shared services) by Neutron RBAC (`access_as_shared`) |
| Created by | the operator, following the [planes contract](../reference/planes-contract.md); `shared/planes` only adopts them | the deployer, with a member role (stack `shared/planes`) |
| A tenant router joins it with | its **gateway** port: traffic leaving the tenant is translated to the gateway's address (`enable_snat`, default, admin-only to change) | an **interface** port: no translation |
| An instance identifiable on the plane | has a **floating IP of the plane** (1:1 translation, its own stable address) | is seen with its real address in the tenant network |
| Routing | none needed: the target answers an address on the plane | through a **transit router** of the hub, the only fixed address on the plane: every attached router routes to it, it routes to every attached router |
| Tenant ranges | may overlap | must not overlap, with each other or with the planes |

- `shared/planes` describes every plane, adopted or built, in one shape (`attachments.<name>.planes`: mode, `nat`, network, routes); the other stacks take only this `plane_attachment` and do not depend on where the planes come from. The tenant stacks, the entry point and the isolation test are the same in both contexts; the common logic is the local module `plane-attachment`.
- **Transit router** (shared private planes). A project cannot choose its address on a network it does not own (Neutron policy `create_port:fixed_ips:ip_address`); the hub can. So the hub creates a transit router at a fixed address of each plane, and the attached routers take an address from Neutron. Each attachment declares a **role per plane**: `shared` (the entry point on `svc_public`, the collector on `monitoring`) or `tenant` (a workload or a target). A tenant routes to the shared services of the plane, a shared service to the tenants (through aggregates when given) and the other shared services, all through the transit router: these routes are known before the attachment exists. Never between two tenants.
- **Discovery.** The plane's owner sees every port on it: `shared/planes` finds the address Neutron gave each attached router and adds one route per attachment on the transit router. Adding a tenant: apply `shared/planes` (RBAC), the tenant's stack, `shared/planes` again; no shared service changes when the tenant's range is inside the aggregates. OpenStack has no route propagation between projects; this is where it happens, at each apply of the hub.
- Routes are not a security boundary: a tenant controls its own router. What isolates tenants, in both modes, is the security groups of each target, admitting only the entry point, the collector or the operators; the isolation test checks it.
- Ports of the instances directly on the planes, without routers, are a known alternative (provider networks, OVHcloud vRack). Not used: no network boundary per tenant, isolation by security groups only, several interfaces per instance to manage. To reconsider on demand.
- The module gives routers interfaces on other networks and static routes (terraform-openstack-tenant, after `v0.1.3`).
- Neutron caps the routes of a router (`max_routes`, 30 by default): a transit router serves about 30 attachments per plane.

### D3 — Repository layout

```
stacks/shared/planes        shared private planes, or adoption of operator planes
stacks/shared/entry-point   the shared public entry point (formerly stacks/20-public-edge)
stacks/tenants/vm           a tenant of virtual machines (formerly stacks/30-tenants/web)
stacks/tenants/isolated     a tenant without public exposure (formerly stacks/30-tenants/isolated)
stacks/tenants/kubernetes   a Kubernetes tenant (formerly stacks/30-tenants/platform)
tests/isolation             the isolation test (formerly tests/reachability)
tests/fixtures              test-only components: collector, intranet service
```

The new paths are a breaking change for existing users: released as a minor version, with the mapping in the changelog. States are not affected.

### D4 — Integration points instead of bundled shared services

The repository provides the **infrastructure of sharing** (planes, entry point) and documents **integration points**: where a shared service lives, how tenants reach it or are reached by it, which sources are admitted, what each tenant stack configures. Today: monitoring (collector addresses, DNS records, metrics ports, cluster federation), the intranet, and publication through the entry point.

- It does not deploy shared services (metrics collector, logs, registry, backups): those are the operator's own tools. They run in projects dedicated to shared services and join their planes with the role `shared`, like the entry point. When several share a project (a Kubernetes cluster), the boundary between them is the cluster's own (namespaces, network policies, sources per Service), not the reference's. The collector and the intranet service of the tests stay test fixtures.
- A companion repository deploying shared services is not started; to reconsider on real demand.

### D5 — Kubernetes as a tenant type

- A Kubernetes tenant is a cluster in a tenant project, created with Cluster API by the tenant's credentials, wired to the shared services like any tenant: published through the entry point, monitored through the monitoring plane, with access to the intranet.
- Its day-to-day operations (Kubernetes upgrade, scaling, credential rotation) are in scope and documented.
- Main use: clouds without a managed Kubernetes offer, and hosts that want the same Kubernetes on every OpenStack cloud they use.
- One cluster per tenant project; multi-tenancy inside a cluster is not provided.

### D6 — The isolation test as an operating tool

The isolation test (formerly "reachability matrix") is presented as a tool to run after every change and as material for customers and auditors. Test results stay in the documentation, not at the top of the README.

## Consequences

- The README leads with the scope, what the reader gets and the two contexts; the single-tenant reader is sent to the module from the first lines.
- A new stack, `shared/planes`, a `plane_attachment` input in every attached stack, and the local modules `plane-attachment`, `bastion` and `admission`.
- No stack reads an object of another project: what a stack needs from another (the entry point's sources, the collector's, the Kubernetes tenant's intranet address) is an output of the latter, passed as an input.
- Tests: the operator-planes context on the reference cloud, as today; the shared-private-planes context on a public cloud (Infomaniak documents network sharing by RBAC), with one project per tenant.
- Settled on the reference cloud (2026-10-31, one project per stack, both modes, isolation test 45/45 each): a member can share a network by RBAC with given projects; a project cannot choose its address on a shared network it does not own; the plane's owner sees every port on it; OVN routes a packet back out of the interface it came in (transit router); Octavia members behind the shared plane work; the cloud controller manager accepts a fixed address for an internal load balancer; MTU 1362 on the plane.
- Still open, to check on a public cloud: the same policies (RBAC sharing by members, owner's view of ports), project limits per account.
