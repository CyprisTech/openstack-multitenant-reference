# ADR-0003: Scope, audience and boundary of the reference

- **Status:** Accepted (implemented in v0.3.0); D3 and D4 refined by [ADR-0009](0009-kubernetes-lifecycle.md) for the Kubernetes lifecycle
- **Date:** 2026-10-30, split on 2026-11-02 into ADR-0003 to ADR-0007
- **Deciders:** maintainers
- **Refines:** [ADR-0001](0001-reference-architecture.md) D1 (scope) and D5 (scenario); [ADR-0002](0002-platform-kubernetes.md) (Kubernetes becomes a tenant type)

## Context

`v0.2.x` addressed teams consuming a cloud with a single application, a case [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) already serves, and assumed the cloud operator provides the shared planes, which excludes every public cloud. What the repository adds is the case its name describes: several tenants, one project each, sharing services, in one region of one cloud.

The needs a reader brings — high availability, backups, logs, audit, single sign-on, quotas — belong to different owners and change at different paces. Without a stated boundary, each of them looks like a gap, and covering them all would turn the reference into a platform two maintainers cannot keep current.

## Options considered

1. **A reference for one application in one project.** Duplicates the module's examples.
2. **An operated platform covering every need of the readers.** Out of reach, and the architecture would disappear under tool choices.
3. **One project per tenant, in one or several regions; the reference owns the multi-tenant architecture and states integration points for the rest** (chosen).

## Decision

### D1 — Purpose and audience

- **Purpose.** Show, with tests as evidence, how to structure your projects on an OpenStack cloud, in one or several regions, for several tenants so that they are isolated from each other, share the common infrastructure and stay available; and how the platform services plug into it.
- **Audience** ([who it is for](../concepts/audiences.md)). Platform teams on a public or sovereign cloud, hosting providers running one project per customer, and operators of a private cloud. The architecture works with a member role only, which is all the first two have; a cloud operator also provides planes as external networks. The profiles are not ranked: what each needs most is shown on the audiences page. The architect evaluating the design is the reader the documentation must convince.

### D2 — Projects by role, in one or several regions

- **Each tenant has its own project**, credentials and quotas.
- **Shared services** (the entry point, a metrics receiver, internal services) run in projects of their own, never with tenant workloads; one such project may host several of them, for example on a Kubernetes cluster ([spec](../specs/kubernetes-shared-services.md)).
- **The hub project holds the network only** when the planes are built with a member role ([ADR-0004](0004-planes-and-isolation.md)): its credentials share the planes and see every port on them, so nothing else runs with them.
- **Projects are created by the organisation that runs them** (the provider's console or API, or cloud-baseline on a private cloud). The stacks consume existing projects; the documentation warns about the project limit of each provider.
- **Regions.** A project is not tied to a region: Keystone is global to a cloud, and a project has resources in each region where it creates some. A stack works in one region, the one of its `clouds.yaml` entry, and the planes, being Neutron networks, exist in one region only. A site (ADR-0001, D9) is one region: several regions are several deployments of the stacks, possibly with the same projects, each with its own planes; they are joined by an encrypted overlay between their hubs ([ADR-0004](0004-planes-and-isolation.md), D5).
- **Keystone domains** only appear in the authentication. Sharing between projects of different domains depends on each cloud's policy.

### D3 — Tenant types

| Type | What it is |
|---|---|
| `vm` | Instances serving domains ([ADR-0006](0006-exposure.md)) |
| `isolated` | A workload with no public exposure, no Internet and no path to other tenants |
| `kubernetes` | A cluster in a tenant project, created with Cluster API by the tenant's credentials, wired to the shared services like any tenant. Its day-to-day operations (upgrade, scaling, credential rotation) are in scope. One cluster per tenant project; multi-tenancy inside a cluster is not provided. Main use: clouds without a managed Kubernetes offer, and hosts wanting the same Kubernetes on every OpenStack cloud they use |

### D4 — Boundary: four levels, the reference owns the second

The levels place a need by owner; the design areas of the README all fall in level 2, with integration points to level 3, except governance, which is level 1.

A need is placed by who owns the decision:

| Level | Question | Examples | Owner | Where |
|---|---|---|---|---|
| 1. Cloud foundation | What do the projects get from the cloud? | projects, quotas, roles, flavors, images, external networks, identity federation, cost | the cloud operator, or the customer through the provider's IAM | cloud-baseline ([terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant)) on a private cloud; the provider's IAM on a public one |
| **2. Multi-tenant architecture** | How are the projects organised, connected, exposed and kept available? | tenants, planes, isolation, entry point, anti-affinity, availability zones, sites, tenant types | the platform architect | **this repository** |
| 3. Platform services | Which shared services run on it? | metrics, logs, audit, security tooling, backup service, secrets | the platform or operations team, with its own tools | integration points of this repository; the tools are yours |
| 4. Workloads | What do the tenants run? | applications, their data and deployments | each tenant | out of scope |

**In scope (level 2)**, including what keeps it running:

- high availability, availability zones, sites and the recovery of the architecture itself (rebuild from code, protection of the states, order of reconstruction);
- the day-to-day operations of what it deploys: the entry point, node images, Kubernetes clusters;
- the network services the tenants need from the architecture: egress, DNS resolution, time, package mirrors, IPv6;
- the certificates of the domains published through the entry point;
- the access and security model ([ADR-0004](0004-planes-and-isolation.md), [ADR-0005](0005-stacks-contracts-and-access.md)). Implementing single sign-on is level 1.

**Integration points (level 3).** For each platform service the reference states where it lives (a project of shared services, a plane), which flows it opens, who is admitted and what each tenant stack configures — not which tool to run. A test fixture (`tests/fixtures`) stands in for the service only to prove the contract. Monitoring is the first one ([ADR-0007](0007-monitoring.md)); logs, audit, backups of tenant data, secrets and a GitOps pipeline follow the same pattern. When several services share a project (a Kubernetes cluster), the boundary between them is the cluster's own.

**Backups are split.** Recovering the architecture is level 2. Backing up the tenants' data is level 3 or 4: the reference only states where backups go and through which plane.

**Out of scope**, said in the README with a pointer: level 1, level 4, the operation of the cloud itself (deployment, upgrades and databases of OpenStack), a single tenant or application (the module and its examples), projects administered by several organisations, an operated platform (projects such as Sovereign Cloud Stack or Azimuth).

**No companion repository for level 3** until real demand shows: tool choices there are opinions that age quickly, two maintainers could not keep them current, and they would hide the architecture.

**Status rule.** The documentation describes the whole design in scope, the target of `v1.0`; the README's status alone gives the release that delivers each part. Its specification and its ADR are written when work on it starts, not before. Integration points get a short specification of the contract only. Out-of-scope needs get only a line in the README.

### D5 — The isolation test as evidence and operating tool

The isolation test checks every flow, allowed and denied, between tenants, shared services and administrators. It is run after every change and is the evidence given to reviewers and auditors. Test results live in the documentation, not at the top of the README.

## Consequences

- The README leads with the scope and the audience; the single-tenant reader is sent to the module from the first lines; the scope is given in three groups — in the reference, integration points, out of scope — and the status maps each design area to its release.
- The decisions of the former ADR-0003 (planes, layout, Kubernetes as a tenant type) are split: planes and isolation in [ADR-0004](0004-planes-and-isolation.md), layout and contracts in [ADR-0005](0005-stacks-contracts-and-access.md), tenant types here (D3).
