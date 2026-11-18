# ADR-0011: Environments — development, qualification, production

- **Status:** Proposed
- **Date:** 2026-11-13
- **Deciders:** maintainers
- **Refines:** [ADR-0003](0003-scope-and-boundary.md) (one project per tenant), [ADR-0005](0005-stacks-contracts-and-access.md) (stacks, contracts, credentials). Related: [open a service after qualification](../guides/open-a-service.md).

## Context

An application usually runs in several environments: development, qualification, production. The reference already isolates them if each one is its own tenant project, and the guide [open a service after qualification](../guides/open-a-service.md) describes how a qualified release reaches production. Three questions remain open:

1. Do the environments share one landing zone (the same planes, hub, entry point and shared services), or does production have its own?
2. How does a promotion work when the projects, planes and names differ between environments?
3. Who holds which credential, what a pipeline does on its own, and how the files of each environment live in the repository without the environments diverging.

The name of every resource carries the site (the name of a region in a deployment) but not the environment, so two deployments of the stacks in the same region would collide.

## Options considered

1. **One landing zone for every environment.** Development, qualification and production are tenants of the same planes, entry point and shared services. Simple and cheap; the isolation between tenants already applies. But a change of a plane, of the entry point or of a shared service reaches production at the same time as development, and is never tried anywhere first.
2. **One landing zone per environment.** Three of everything. The cleanest separation, but the cost of the shared layer is paid three times for environments that rarely need it.
3. **One landing zone per tier: non-production and production** (chosen). Development and qualification are tenants of the non-production landing zone; production has its own planes, hub, entry point and shared services. Each change of the landing zone itself is applied to non-production first. This is the common practice of the landing zones of public clouds, which separate production and non-production accounts, often with a network hub each.

## Decision

### D1 — Two tiers, one landing zone each

- A deployment has a **non-production** landing zone and a **production** landing zone: each with its own projects, planes (operator networks or a hub project), entry point and shared services. In one region or several.
- **An environment of an application is a tenant project:** `app-dev` and `app-qualif` in non-production, `app` in production. Two environments never share a project.
- **Nothing crosses the tiers through the planes.** No route, plane or admission rule joins a non-production project to a production one. The only exception is the artifact registry (D4).
- A single landing zone for every environment (option 1) remains acceptable for a small deployment, with its cost stated: changes of the shared layer are not tried before production.

### D2 — The environment is part of every name

- Every stack takes the **environment tier** as an input, next to the site, and includes it in the names of its resources and in its state key: two tiers in the same region never collide.
- The address ranges of the two tiers do not overlap, so that a service can later be shared without renumbering.

### D3 — Same code, declared differences

- Both tiers apply the **same release** of the reference, with the same module releases; production may lag one release behind while a change is qualified (D6). What differs is **declared in one input file per tier and per stack**, reviewed like code: the site and tier, the projects and their credentials, the address ranges, the domains, the sizes, the administrator addresses.
- **Each tier's contracts come from that tier's outputs only** ([ADR-0005](0005-stacks-contracts-and-access.md), D3): a production tenant receives its `plane_attachment`, its admission sources and its receiver from the production stacks. No input file names an object of the other tier, so a different name or address between tiers cannot leak from one to the other.
- **Reachability is a difference of the tier, not of the tenants.** To keep the non-production tier off the Internet, its entry point takes its floating IP on an internal network (the organisation's intranet or VPN) through its `public_network` input (which also gives the edge network its way out: that network must reach the package sources and the certificate authority), and the tenants keep `exposure = "entry-point"`: the same stacks and inputs give a non-production tier reachable from inside only and a public production tier. Tenants do not switch their exposure between tiers; a promotion changes the landing zone an artifact runs in, not how it is published.
- **Applications find their dependencies by name, never by address:** the internal services through the internal zone of their tier, the receiver through its URL given as an input. The same artifact runs in both tiers with no change.

### D4 — What is promoted, and how

| What | How it is promoted |
|---|---|
| An application release | Its artifact, by digest or ID ([open a service](../guides/open-a-service.md)): built once, qualified in non-production, deployed unchanged in production. The artifact registry is the one service both tiers reach: pipelines push to it, both tiers pull from it. Where it runs (a shared service of production, or outside the landing zones) is a choice of the platform. |
| A change of the landing zone | A new release of the reference, pinned and applied in non-production, checked (empty plan, isolation test), then pinned in production (D6). |
| Opening a service to its users | A separate reviewed change in production: a domain on the entry point, or consumers of an internal service ([open a service](../guides/open-a-service.md)). |

What is **not** promoted, by design: secrets and certificates (each tier obtains its own), data, and the credentials of each project.

### D5 — Who holds which credential

- **Each project has its own credential** ([ADR-0005](0005-stacks-contracts-and-access.md), D2), so access follows the tiers without any new mechanism.
- **Production credentials are held by the pipeline**, in its secret store, and used only after a reviewed merge. People who develop an application work in non-production; whether the same people also operate production is the organisation's choice, and the reference supports both: the separation is carried by the credentials and the review, not by the team.
- Administration of production instances goes through the bastions of the production stacks, from named administrator addresses ([ADR-0005](0005-stacks-contracts-and-access.md), D5).

### D6 — A deployment repository, one directory per tier

- **The reference is consumed by release, not forked.** A deployment keeps its own repository, separate from the reference, with one directory per tier: `environments/non-production/` and `environments/production/`. Each directory pins a **release of the reference** (a tag) and holds the backend and state keys of its stacks and one input file per stack. Nothing else of the reference is copied.
- **The pipeline applies a tier from its directory:** it checks out the reference at the pinned release, then runs each stack of that checkout with the tier's backend configuration and input file. The stacks declare no backend, and take every input from outside, so they run unchanged for any tier.
- **A change of the landing zone is a change of the pinned release.** It is made first in the non-production directory, applied and checked (empty plan after apply, isolation test); the same release is then pinned in the production directory, as a reviewed change that runs after an approval. Production can lag behind non-production by a release; it never runs code that non-production has not run.
- **A change for one tier only touches that tier's directory:** a domain opened in production, the sizes of production, the digest of an application release. A commit of the deployment repository is never applied to both tiers at once.
- **Today, before this layout is supported** (see Consequences), a deployment uses one clone of the reference per tier, each checked out at the same release, with its input files and backend kept in that clone and outside the repository. It is the same model with the directory replaced by a clone.
- **One repository per tier** instead of one directory per tier is accepted when access to production must be separated at the repository level: the production repository is then readable and writable only by those who operate production.
- Set aside: **a branch per environment.** Promotions become merges or cherry-picks between branches, the branches drift, and what runs in production is no longer a release of the reference.
- Checks the pipeline adds: both tiers' input files declare the same keys; a scheduled plan in each tier reports drift; the release running in each tier is visible.

## Consequences

- A new input, the environment tier, in every stack and in the names; the README's terms and the architecture describe the two tiers; the isolation test runs in each tier, and a check that no route or rule crosses the tiers.
- Twice the shared layer: two sets of planes, two entry points, two sets of shared services. For a small deployment, option 1 is documented as the cheaper alternative, with its limit.
- Supporting the deployment repository of D6 is planned with the GitOps integration point (v0.7): `scripts/publish-domains.sh` takes the location of the tenant states and of the domains file instead of the paths of the repository, and an example deployment repository shows the two tier directories. The stacks themselves need no change. They are not meant to be called as modules from the deployment repository: they configure their provider, which would forbid `count` and `for_each` on the call.
- The pipeline itself (its tool, its jobs) stays an integration point ([ADR-0003](0003-scope-and-boundary.md), D4); the reference states what it promotes and with which credential.
- Open: whether the artifact registry is a shared service of production or lives outside both landing zones; how the non-production tier reaches it if it is in production (a plane of production that non-production joins as a consumer would be the one route between tiers).
