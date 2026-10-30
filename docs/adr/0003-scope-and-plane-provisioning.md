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

- **One OpenStack account, one project per tenant.** Shared services live in one or more **hub** projects of the same account; each tenant has its own project, credentials and quotas. The shared planes play, inside one account, the role a transit gateway plays between networks on other clouds: a hub-and-spoke that OpenStack does not offer natively.
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
| A plane is | an external network created by the cloud operator | a private network of a hub project, shared with the tenant projects by Neutron RBAC (`access_as_shared`) |
| Created by | the operator, following the [planes contract](../reference/planes-contract.md); `shared/planes` only adopts them | the deployer, with a member role (stack `shared/planes`) |
| A tenant router joins it with | its **gateway** port: traffic leaving the tenant is translated to the gateway's address (`enable_snat`, default, admin-only to change) | an **interface** port: no translation |
| An instance identifiable on the plane | has a **floating IP of the plane** (1:1 translation, its own stable address) | is seen with its real address in the tenant network |
| Return path | none needed: the target answers an address on the plane | **router routes in both directions** between each tenant and the shared services, generated from the stacks' outputs (ADR-0001, D9); never between two tenants |
| Tenant ranges | may overlap | must not overlap, with each other or with the planes |

- The mode is an input of the stacks, per plane. The tenant stacks, the entry point and the isolation test are the same in both contexts.
- Routes are not a security boundary: a tenant controls its own router. What isolates tenants, in both modes, is the security groups of each target, admitting only the entry point, the collector or the operators; the isolation test checks it.
- Ports of the instances directly on the planes, without routers, are a known alternative (provider networks, OVHcloud vRack). Not used: no network boundary per tenant, isolation by security groups only, several interfaces per instance to manage. To reconsider on demand.
- The module needs router routes (`openstack_networking_router_route_v2`) for mode 2.

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

- It does not deploy shared services (metrics collector, logs, registry, backups): those are the operator's own tools. The collector and the intranet service of the tests stay test fixtures.
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
- A new stack, `shared/planes`, and a `binding` input per plane in the tenant stacks and the entry point.
- Tests: the operator-planes context on the reference cloud, as today; the shared-private-planes context on a public cloud (Infomaniak documents network sharing by RBAC), with one project per tenant.
- Open points, settled by those tests: network RBAC sharing allowed to members, Octavia members on a shared private network, MTU of shared private networks, project limits per account.
