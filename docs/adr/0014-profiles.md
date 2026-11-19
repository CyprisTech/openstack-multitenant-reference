# ADR-0014: Two profiles, private cloud and public cloud

- **Status:** Proposed
- **Date:** 2026-11-19
- **Deciders:** maintainers
- **Refines:** [ADR-0003](0003-scope-and-boundary.md) (audiences), [ADR-0004](0004-planes-and-isolation.md) D1 (plane modes), [ADR-0005](0005-stacks-contracts-and-access.md) (administration access), [ADR-0012](0012-resilience-scope.md) (what is tested)

## Context

The reference serves two situations that differ in the field:

| | Private cloud (the operator) | Public cloud (a customer) |
|---|---|---|
| Rights | admin, through [cloud-baseline](https://github.com/CyprisTech/terraform-openstack-cloud-baseline): operator planes, address scopes | member role only |
| Planes | operator planes or a hub | a hub only |
| Administration network | an intranet, to keep away from the tenants | the Internet, the same network as the egress |
| DNS | Designate often present | often absent |
| Main constraint | integration with what exists, day-2 operations, coverage | footprint within the default quotas, cost of every load balancer, floating IP and instance |

One deployment and one test campaign for both would be badly fitted: too heavy and too costly on a public cloud, where the default quotas are small (on the public cloud we checked: 4 routers, 10 security groups, 40 ports per project), and testing again on a public cloud what the private cloud campaign already proves.

The core does not differ: planes by role, the entry point, the isolation model, plane routes on a transit router ([ADR-0013](0013-plane-routes-on-a-transit-router.md)), the tenant types. What differs is at the edge: administration access, plane mode, DNS, footprint.

## Options considered

1. **One reference, one campaign for every cloud.** The public cloud run either needs raised quotas and costs every scenario again, or is a subset nobody names.
2. **Two references, one per kind of cloud.** The core is duplicated and drifts; the message "the same model on every OpenStack cloud" is lost.
3. **One reference, two named profiles, each with its examples and its campaign** (chosen).

## Decision

### D1 — Two profiles

A profile is a documented combination of inputs, with its example and its test campaign. There are two:

| | `private-cloud` | `public-cloud` |
|---|---|---|
| Planes | operator planes or hub planes | hub planes |
| Bastion | on its own network, whose router joins the administration network | on the stack's network, its floating IP on the stack's router to the administration network when that network is also its egress (D2) |
| Internal names | Designate, when the cloud has it | none required: shared services are reached by address until the network services serve the internal zone (`v0.6`) |
| Footprint | no target | within the default quotas of a public project: at most 4 routers per project |

Other combinations stay possible through the inputs; they are not tested by the maintainers.

### D2 — A bastion on the stack's network

The bastion keeps its own network when the administration network is an intranet: the stack's network must not get a path to it. When the administration network is the same as the stack's egress (the Internet on a public cloud), that separation adds nothing: the bastion may take its port on the stack's network and its floating IP on the egress router (the public router for the entry point). Its replies follow the default route of the subnet, through the transit router to that same router, so the path is symmetric. It saves a network and a router per project. A stack with no egress (`isolated`) keeps the bastion on its own network.

### D3 — A campaign per profile

- `private-cloud`: the full campaign, both plane modes. It proves the core.
- `public-cloud`: what differs from the private cloud, on a public cloud with the member role: the hub planes shared between projects, the provider's Neutron and Octavia, the transit router, publication and direct exposure from the real Internet, no Designate, the default quotas, the cost of a run. Kubernetes, certificates from an internal authority, the internal service and the operator planes are not run again.

The campaign tooling is shared: generic steps, a scenario per profile, and the profile's example inputs, the same ones the documentation shows.

## Consequences

- The bastion module and the stacks get an input for D2; the default stays the bastion on its own network.
- `examples/private-cloud` and `examples/public-cloud` show the inputs of each profile.
- The campaign tooling is reorganised into steps, scenarios and example inputs, in Python with its standard library only (the isolation test is already written in it).
- The README's status and the test results say what each profile has tested.
- A project of the public profile needs no raised quota; the number of projects stays one per stack.
