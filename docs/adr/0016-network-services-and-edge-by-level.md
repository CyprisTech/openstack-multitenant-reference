# ADR-0016: Network services and the edge, by level

- **Status:** Accepted
- **Date:** 2026-11-23
- **Deciders:** maintainers
- **Refines:** [ADR-0003](0003-scope-and-boundary.md) D3 (the tenant types: `isolated` becomes a configuration of `vm`, D1) and D4 (network services in scope: egress, DNS resolution, time, package mirrors), [ADR-0004](0004-planes-and-isolation.md) (planes), [ADR-0006](0006-exposure.md) (exposure)
- **Supersedes:** [ADR-0006](0006-exposure.md) D3 for the source of the routes of the entry point (D5 below); their delivery as instance metadata is kept

## Context

ADR-0003 puts the network services the tenants need in level 2: egress, DNS resolution, time, package mirrors. ADR-0006 adds a shared entry point, whose routes are gathered from the outputs of the tenants' states. Before designing v0.6, the maintainers compared with the landing zones of the large providers, and with what an OpenStack cloud offers its tenants:

| Service | Landing zones of the large providers | An OpenStack cloud |
|---|---|---|
| Egress | central in the landing zone (a network account or hub: NAT, a firewall, its logs); application accounts have no direct way out | each project's router to an external network; nothing central |
| Ingress | an application's own load balancer by default; a central entry (a perimeter network, a hub gateway) as an option, its rules managed by the network team as code | an Octavia load balancer per project; no entry shared between projects |
| Internal DNS | private zones and resolver endpoints in the landing zone's network account or hub; the records written by the teams or their tools | Designate on some clouds, not on every public one; otherwise the organisation's DNS, outside OpenStack |
| Recursive DNS and time | provided by the cloud on a link-local address, reachable from every network | recursive DNS through Neutron's DHCP; no time service for tenants, but instances on KVM follow the hypervisor's clock (kvm-clock) |
| Package mirrors, registry caches | run by platform or workload teams (pull-through caches, private repositories) | none |

Three facts of the reference itself:

- Every stack writes resolvers in its subnet, given as inputs; the examples use public resolvers, which the `isolated` tenant, without egress, cannot reach.
- Two stacks run virtual machines: `vm`, exposed and with an egress, and `isolated`, with neither; they differ only by these two properties.
- Each stack writes its own DNS records, in Designate only (the `dns` module of terraform-openstack-tenant): on a cloud without Designate, the stacks cannot be applied with their names.
- The routes of the entry point are gathered by a script that reads the outputs of every tenant's state, then delivered as instance metadata. The script couples the entry point to every tenant's state, and nothing reviews a new route.

## Options considered

1. **Every network service in level 2** (the first design of v0.6): resolvers, time servers, package and image caches as shared services of the reference. It runs services the cloud or the platform teams usually provide, and makes the reference responsible for mirrors it cannot keep up to date for every distribution and registry.
2. **Nothing in level 2**: tenants use what the cloud offers, egress included. It leaves the central concern of every landing zone, which tenant may go out, undecided.
3. **By level** (chosen): the landing zone owns what the landing zones of the large providers own, requires of the cloud what an OpenStack cloud provides, and connects to the rest.

For the records on a cloud without Designate, the maintainers set aside, for now, a write by RFC 2136 towards the organisation's DNS, and a relay of the reference serving the internal zone: an output the user publishes is enough, and either can come later, on demand.

For the routes of the entry point:

- **A reviewed list of routes** (chosen, D5): an input of the entry point, kept in the deployment repository, a new route added by a reviewed change.
- **A registry of routes**, a small service where each tenant declares its domains, read by a dynamic provider of Traefik: self-service, but a stateful service to secure, back up and keep available. Not built.
- **A shared Gateway API** on a platform cluster, each tenant declaring its routes in its namespace: the self-service way of today, level 3 ([trade-offs](../concepts/trade-offs.md#1-tls-passthrough-at-the-public-entry-point)).

## Decision

### D1 — Egress and exposure are declared per tenant

Each tenant declares its egress: `none`, `router` (its own router to an external network, as today) or `shared` (a shared egress of the landing zone that restricts and logs). With `none`, the tenant has no default route. Egress is the central concern of every landing zone; it stays in the reference.

Each tenant also declares its exposure: `none`, `entry-point` or `public` ([ADR-0006](0006-exposure.md)). A tenant with neither exposure nor egress is a private tenant, as the landing zones of the large providers separate the workloads connected to the hub only from those exposed to the Internet, by policy rather than by kind of workload. The `isolated` tenant type of ADR-0003 D3 therefore becomes a configuration of the `vm` stack (`exposure = "none"`, `egress = "none"`), and its stack is removed. A tenant without egress gets its software from its image or from a package mirror (D4).

### D2 — Each stack writes its records in Designate, and gives them as an output

The naming of the landing zone (the zones and the names of the shared services) is level 2; the DNS service is level 1, or the organisation's. Each stack keeps writing its own records in Designate, with its own credentials, as the cloud's native service does today. On a cloud without Designate, it writes none. In both cases it gives them as an output, `dns_records`, which the user publishes with their own DNS provider.

### D3 — Recursive DNS and time are requirements on the cloud

The reference runs no resolver and no time server. A tenant's resolvers come from Neutron's DHCP (the operator's, set in Neutron's configuration), from the operator or the Internet through the tenant's egress, or from a resolver behind a plane the tenant joins: the operator's, the organisation's DNS, a platform team's service. A stack takes them as an input (`dns_nameservers`), empty to keep the DHCP's. The reference requires that they resolve the zones of the landing zone, and that the hypervisors keep time: instances on KVM follow them through kvm-clock. A workload that needs NTP-grade accuracy brings its own time servers. On a cloud with no resolver reachable without egress, and without a DNS of the organisation, a tenant without egress resolves no name: the planes contract states it.

### D4 — Package mirrors and registry caches are integration points

They are tools of the platform teams (level 3), as metrics, logs and backups ([ADR-0007](0007-monitoring.md)). The reference states where they connect (a project of shared services, a plane), how a tenant without egress reaches them and what a tenant stack configures (mirror and registry addresses); a test fixture may stand in for them.

### D5 — The routes are a reviewed input of the entry point

The routes of the entry point (each domain and the service address it goes to) are an input of its stack, kept in the deployment repository; a tenant asks for a new route with a change that is reviewed and merged. The publication no longer reads the tenants' states. Their delivery stays as in ADR-0006 D3: instance metadata, updated in place, rendered by a timer on each instance, so that a change of routes replaces no instance.

## Consequences

- The isolation test checks that every tenant resolves a name of the landing zone's zone and a public name through the expected resolver, and that a tenant without egress has no path to the Internet. Time is a requirement on the cloud, not a row: a wrong clock would also fail the HTTPS checks, which verify certificates.
- The `isolated` stack is removed: the private tenant of the test scenario is a `vm` stack with `exposure = "none"` and `egress = "none"`. A deployment of `isolated` is redeployed with `vm`.
- The planes contract states what the cloud must provide (D3).
- The stacks take the choice of `designate` or not as an input, and give `dns_records` (D2); the `dns` module of terraform-openstack-tenant is unchanged.
- `scripts/publish-domains.sh` no longer reads the tenants' states: it applies the routes of the entry point's input (D5). Each tenant stack keeps its `published_domains` output, to fill in the change that asks for a route.
- The entry point stays a layer-4 entry, optional, next to direct exposure; what needs decryption is level 3 ([trade-offs](../concepts/trade-offs.md#1-tls-passthrough-at-the-public-entry-point)).
- ADR-0003 D4 keeps network services in level 2, with this split; ADR-0006 D3 is superseded for the source of the routes.
