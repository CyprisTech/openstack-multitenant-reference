# ADR-0005: Stacks, contracts between them, and access

- **Status:** Proposed
- **Date:** 2026-11-02 (from ADR-0003 D3 of 2026-10-30 and decisions taken in the reviews of 2026-10-30 and 2026-10-31)
- **Deciders:** Gregory Gabrielian
- **Refines:** [ADR-0001](0001-reference-architecture.md) D1 (layers, stacks found by name); [ADR-0002](0002-platform-kubernetes.md) D6 (administration and intranet)

## Context

`v0.2.x` organised the stacks in numbered layers (`10`, `20`, `30`) and let a stack find another's objects by name. With one project per tenant ([ADR-0003](0003-scope-and-boundary.md)), a stack can no longer read the objects of another project, and the same logic (joining the planes, a bastion, admission rules) was repeated in every stack.

## Options considered

1. **Remote state between stacks.** Couples the stacks to one backend and gives each stack read access to the others' states, secrets included.
2. **Lookups by name across projects.** Impossible with project-scoped credentials.
3. **Outputs passed as inputs, one description of the planes, shared building blocks** (chosen).

## Decision

### D1 — Layout

```
stacks/shared/planes        the planes: adopted from the operator, or built in the hub project
stacks/shared/entry-point   the shared public entry point
stacks/tenants/vm           a tenant of virtual machines
stacks/tenants/isolated     a tenant without public exposure
stacks/tenants/kubernetes   a Kubernetes tenant
modules/                    building blocks used by the stacks (D4)
tests/isolation             the isolation test
tests/fixtures              stand-ins for platform services, for the tests only
images/kubernetes-node      the node image of the Kubernetes tenant
```

### D2 — One state, one credential per stack

- Each stack has its own state and its own `clouds.yaml` entry: an application credential scoped to the stack's project, with the roles `member` and `load-balancer_member` (a second one, for the cluster itself, in a Kubernetes tenant). No stack holds an administrator role.
- The state backend is the deployer's choice; states contain secrets and are protected as such. Their protection belongs to the recovery of the architecture, on the roadmap.

### D3 — Contracts are outputs passed as inputs

- **No stack reads an object of another project.** What a stack needs from another is an output of the latter, passed as an input: the `plane_attachment` of each stack from `shared/planes`; the entry point's source addresses (`svc_public_sources`) for the tenants' admission rules; the published domains of each tenant (`published_domains`) for the entry point; the Kubernetes tenant's intranet sources (`intranet_sources`) for an internal service.
- **`shared/planes` is the single description of the planes** ([ADR-0004](0004-planes-and-isolation.md)): `plane_attachment` is the only plane input of the other stacks.
- The order of application follows the contracts: planes, shared services, entry point, tenants, planes again on `interface` planes, domains published.

### D4 — Shared building blocks

The logic every stack needs is written once, as local modules:

| Module | Role |
|---|---|
| `plane-attachment` | routers, routes and exposure of a stack on its planes, from its `plane_attachment` |
| `bastion` | an optional administration instance, reachable from the operators' addresses only |
| `admission` | security group rules from declared flows, keyed `<flow>-<port>-<source>` |
| `plane-discovery`, `range-overlaps` | the discovery of attached routers and the range checks of `shared/planes` |

The building blocks of one tenant (network, instances, load balancers, DNS) come from [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant), pinned to a published release in every stack.

### D5 — Administration paths

- **Two roles, administration and intranet** (ADR-0002, D6). Administration endpoints — a stack's bastion, the Kubernetes API — admit **named operator addresses only**, never the range of a plane. Recommended: a dedicated administration network; accepted: one network for both roles, with restricted sources.
- **Instances admit SSH from their stack's bastion and from named operator addresses only**, none by default. An operator reaches an instance through the bastion of its stack, the bastion through the administration network.
- Single sign-on to these endpoints, and the audit of administration access, are level 1 and 3 ([ADR-0003](0003-scope-and-boundary.md), D4).

## Consequences

- Breaking for `v0.2.x` users: paths and some inputs, with the mapping in the changelog. States are not affected by the new paths.
- A stack can be applied, reviewed and owned by a different team: its contract with the others is its inputs and outputs.
- Passing outputs between stacks is done by the deployer (or a pipeline); `scripts/publish-domains.sh` does it for the published domains.
