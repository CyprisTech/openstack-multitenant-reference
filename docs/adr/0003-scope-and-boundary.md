# ADR-0003: Scope, audience and boundary of the reference

- **Status:** Proposed
- **Date:** 2026-10-30, split on 2026-11-02 into ADR-0003 to ADR-0007
- **Deciders:** Gregory Gabrielian
- **Refines:** [ADR-0001](0001-reference-architecture.md) D1 (scope) and D5 (scenario); [ADR-0002](0002-platform-kubernetes.md) (Kubernetes becomes a tenant type)

## Context

`v0.2.x` addressed teams consuming a cloud with a single application, a case [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) already serves, and assumed the cloud operator provides the shared planes, which excludes every public cloud. What the repository adds is the case its name describes: several tenants, one project each, in one account, sharing services.

The needs a reader brings — high availability, backups, logs, audit, single sign-on, quotas — belong to different owners and change at different paces. Without a stated boundary, each of them looks like a gap, and covering them all would turn the reference into a platform two maintainers cannot keep current.

## Options considered

1. **A reference for one application in one project.** Duplicates the module's examples.
2. **An operated platform covering every need of the readers.** Out of reach, and the architecture would disappear under tool choices.
3. **One account, one project per tenant; the reference owns the multi-tenant architecture and states integration points for the rest** (chosen).

## Decision

### D1 — Purpose and audience

- **Purpose.** Show, with tests as evidence, how to structure one OpenStack account for several tenants so that they are isolated from each other, share the common infrastructure and stay available; and how the platform services plug into it.
- **Audience** ([who it is for](../concepts/audiences.md)). Primary: platform teams on a public or sovereign cloud with a member role, and hosting providers running one project per customer. Secondary: operators of a private cloud, who provide the planes. The architect evaluating the design is the reader the documentation must convince.

### D2 — One account, projects by role

- **Each tenant has its own project**, credentials and quotas.
- **Shared services** (the entry point, a metrics receiver, internal services) run in projects of their own, never with tenant workloads; one such project may host several of them, for example on a Kubernetes cluster ([spec](../specs/kubernetes-shared-services.md)).
- **The hub project holds the network only** when the planes are built by the account holder ([ADR-0004](0004-planes-and-isolation.md)): its credentials share the planes and see every port on them, so nothing else runs with them.
- **Projects are created by the account holder** (the provider's console or API, or cloud-baseline on a private cloud). The stacks consume existing projects; the documentation warns about the project limit of each provider.
- **Regions.** A stack works in one region, the one of its `clouds.yaml` entry. A site (ADR-0001, D9) is one region: several regions are several deployments of the stacks.
- **Keystone domains** only appear in the authentication. Sharing between projects of different domains depends on each cloud's policy.

### D3 — Tenant types

| Type | What it is |
|---|---|
| `vm` | Instances serving domains ([ADR-0006](0006-exposure.md)) |
| `isolated` | A workload with no public exposure, no Internet and no path to other tenants |
| `kubernetes` | A cluster in a tenant project, created with Cluster API by the tenant's credentials, wired to the shared services like any tenant. Its day-to-day operations (upgrade, scaling, credential rotation) are in scope. One cluster per tenant project; multi-tenancy inside a cluster is not provided. Main use: clouds without a managed Kubernetes offer, and hosts wanting the same Kubernetes on every OpenStack cloud they use |

### D4 — Boundary: four levels, the reference owns the second

A need is placed by who owns the decision:

| Level | Question | Examples | Owner | Where |
|---|---|---|---|---|
| 1. Cloud foundation | What does the account have? | projects, quotas, roles, flavors, images, external networks, identity federation, cost | the cloud operator, or the account holder through the provider's IAM | cloud-baseline ([terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) `v0.2`) on a private cloud; the provider's IAM on a public one |
| **2. Multi-tenant architecture** | How is the account divided, connected, exposed and kept available? | tenants, planes, isolation, entry point, anti-affinity, availability zones, sites, tenant types | the platform architect | **this repository** |
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

**Out of scope**, said in the README with a pointer: level 1, level 4, the operation of the cloud itself (deployment, upgrades and databases of OpenStack), a single tenant or application (the module and its examples), tenants in several accounts or clouds (an encrypted overlay is a later direction), an operated platform (projects such as Sovereign Cloud Stack or Azimuth).

**No companion repository for level 3** until real demand shows: tool choices there are opinions that age quickly, two maintainers could not keep them current, and they would hide the architecture.

**Roadmap rule.** Every in-scope or integration-point need is on the roadmap, with a target release. Its specification and its ADR are written when work on it starts, not before. Integration points get a short specification of the contract only. Out-of-scope needs get only a line in the README.

### D5 — The isolation test as evidence and operating tool

The isolation test checks every flow, allowed and denied, between tenants, shared services and operators. It is run after every change and is the material shown to customers and auditors. Test results live in the documentation, not at the top of the README.

## Consequences

- The README leads with the scope and the audience; the single-tenant reader is sent to the module from the first lines; the roadmap is sorted in three groups: in the reference, integration points, out of scope.
- The decisions of the former ADR-0003 (planes, layout, Kubernetes as a tenant type) are split: planes and isolation in [ADR-0004](0004-planes-and-isolation.md), layout and contracts in [ADR-0005](0005-stacks-contracts-and-access.md), tenant types here (D3).
