# Spec: network services and the edge

- **Status:** Proposed — its release is given in the README's [status](../../README.md#status) (`v0.6`)
- **Related:** [ADR-0016](../adr/0016-network-services-and-edge-by-level.md) (network services and the edge, by level), [ADR-0003](../adr/0003-scope-and-boundary.md) D4, [ADR-0006](../adr/0006-exposure.md) (exposure), [ADR-0015](../adr/0015-ipv6.md) (IPv4 only), [planes contract](../reference/planes-contract.md), [architecture](../concepts/architecture.md#network-services)

## Problem

- **Egress is not declared.** A tenant with an egress router reaches the Internet with no restriction or log beyond its own security groups; nothing says which tenant may go out.
- **The resolvers are public addresses given as inputs.** Each stack writes resolvers in its subnet (`dns_nameservers`); the examples use public ones, which the `isolated` tenant cannot reach since it has no egress. The reference states nothing about what the cloud must provide for name resolution and time.
- **The records need Designate.** Each stack writes its records in Designate only: on a cloud without it, the stacks cannot be applied with their names.
- **Two stacks for virtual machines.** `vm` and `isolated` differ only by their exposure and their egress.
- **The routes of the entry point are gathered from the tenants' states.** The publication reads every tenant's state, and nothing reviews a new route.

## Goal

The split of [ADR-0016](../adr/0016-network-services-and-edge-by-level.md):

- **Egress and exposure declared per tenant** (D1): egress `none`, `router` or `shared`, the shared egress restricting and logging; exposure `none`, `entry-point` or `public`. The `isolated` stack becomes a configuration of `vm`: a private tenant.
- **Records in Designate, or as an output** (D2): each stack writes its records in Designate when the cloud has it, and gives them as an output (`dns_records`) for the user to publish elsewhere.
- **Recursive DNS and time as requirements on the cloud** (D3): the resolvers come from Neutron's DHCP, time from the hypervisor through kvm-clock.
- **Package mirrors and registry caches as an integration point** (D4), released in `v0.8` with the other integration points.
- **The routes of the entry point as a reviewed input** (D5).

Out of scope: running a DNS service, time servers, a relay or package repositories; writing records by RFC 2136 (a later extension, on demand); TLS termination, routing by path or a web application firewall at the entry point (level 3, [trade-offs](../concepts/trade-offs.md#1-tls-passthrough-at-the-public-entry-point)); a registry of routes; routed operator planes, released in `v0.7` with cloud-baseline.

## Design

1. **Routes of the entry point**: the `domains` input of `stacks/shared/entry-point` (each domain and its service address), its file `domains.auto.tfvars.json` kept in the deployment repository. `scripts/request-domains.sh` writes the domains of one tenant into it, from that tenant's `published_domains` output: the change of the merge request. `scripts/publish-domains.sh` plans and applies the entry point from that file instead of reading the tenants' states; their delivery as instance metadata is unchanged.
2. **Resolvers and time**: `dns_nameservers` stays an input of every stack, empty by default. A tenant's resolvers come from one of three sources:

   | Source | `dns_nameservers` | For |
   |---|---|---|
   | Neutron's DHCP: the operator's resolvers, set in Neutron's configuration | empty | a cloud whose resolvers the subnet reaches (the DHCP agent's dnsmasq with ML2/OVS, or resolvers routed to the tenant) |
   | The operator's resolvers, or public ones, through the tenant's egress | their addresses | a tenant with an egress |
   | A resolver behind a plane the tenant joins: the operator's on an operator plane, the organisation's DNS through a hub plane, a platform team's service on `internal` | its address, a destination of one of the tenant's planes | a tenant without egress, such as `isolated`, in particular with ML2/OVN, where the subnet only receives the resolvers' addresses |

   The reference runs none of them. The [planes contract](../reference/planes-contract.md) states the requirements: the tenant's resolvers resolve the zones the landing zone uses, and the hypervisors keep time (instances on KVM follow them through kvm-clock). It also states the limit: on a cloud with no resolver reachable without egress, and without a DNS of the organisation, `isolated` resolves no name. A workload that needs NTP-grade accuracy brings its own time servers (level 3 or 4). The examples drop their public resolvers. The [security page](../concepts/security.md) notes that a resolver which also answers public names is a narrow way out for a tenant without egress; a DNS that serves only the internal zones closes it.
3. **Records**: each stack takes `dns = "designate" | "output"`. With `designate`, it writes its records as today; with `output`, it writes none. In both cases its `dns_records` output is a map keyed by `"<name> <type>"`, each value `{ zone, name, type, ttl, records }`: it goes straight into a `for_each` of any DNS provider, and tools such as OctoDNS or external-dns convert it. No zone file fragment.
4. **Egress and exposure**: `vm` takes `exposure = "none"` next to `entry-point` and `public`: no service address, no route to the publication plane, an empty `published_domains`. An `egress` input per tenant stack: `none` (no default route on the transit router), `router` (today's egress router, unchanged), `shared` (no default route either: the tenant's instances get the proxy's address as `HTTP_PROXY`, reached on the `internal` plane). The private tenant takes `exposure = "none"` and `egress = "none"`; the `isolated` stack is removed. The `kubernetes` stack takes `exposure = "none"` too: a private cluster, with no ingress and no service address, its applications reached by nothing but the administration path; it keeps its egress router, which brings its container images. Its `egress = "none"` needs a registry mirror, and comes with the integration point of mirrors (part 5, `v0.8`).
5. **Mirrors and caches** (`v0.8`): the integration point states the plane, the admission and the tenant inputs (a package mirror URL, registry mirrors for `containerd`); a test fixture stands in for them.
6. **Tests**: the isolation test gets rows per tenant: the resolver in use (`resolvectl`) is the expected one, a name of the landing zone's zone and a public name resolve, the private tenant reaches no address on the Internet; for a tenant with `egress = none`, no default route. A fixture, `tests/fixtures/resolver` (Unbound on the `internal` plane, forwarding through the egress of its own project), stands in for the resolver behind a plane, as `receiver` stands in for a metrics receiver; on the public cloud profile, where there is no project of internal services, it runs in the project of `receiver`. The campaigns cover the three sources: Neutron's DHCP (checked on each cloud at the first deployment), public resolvers through the egress, the fixture for the private tenant, which joins the `internal` plane for it. No row for time: it is a requirement on the cloud, and a wrong clock would fail the HTTPS checks. The stacks' mocked tests check `dns_records` in both modes of `dns`.
7. **Name resolution inside the clusters**: CoreDNS forwards to the node's resolvers, those of the subnet; no stub zone by default. A private zone the cloud's resolvers do not resolve is a setting of the platform team's CoreDNS (level 3), documented, not delivered.

## Dependencies and order

1. The routes of the entry point as an input (part 1): it changes the publication, not the tenants.
2. Declared egress and exposure, `none` and `router` (part 4): the private tenant as a `vm` stack, the `isolated` stack removed; the default of each stack stays what it is today.
   Then `exposure = "none"` for the `kubernetes` stack.
3. Resolvers and time as requirements (part 2), name resolution in the clusters (part 7), and the rows of the isolation test that check them (part 6).
4. Records in Designate or as an output (part 3), then a campaign on the public cloud profile without Designate.
5. The shared egress (part 4, `shared`).

The integration point of mirrors and caches (part 5), and with it `egress = "none"` for the `kubernetes` stack, comes in `v0.8` with the other integration points.

Each step is delivered and tested on its own, with a campaign in the plane modes it touches.

## Proposed decisions

The decisions are in [ADR-0016](../adr/0016-network-services-and-edge-by-level.md). In the design:

- **The routes keep their delivery by metadata**: it changes the routes without replacing an instance, and an outage never removes a route. Only their source changes.
- **`dns_records` in both modes**: the same output whatever the cloud, so that a deployment can move between clouds, or publish some names in a second DNS, without changing the stacks.
- **The shared egress is Squid on the `internal` plane**: a forward proxy that restricts by name and logs every connection, which a router with address translation cannot; on `internal`, which the tenants that go out already join, it costs no router (the public profile allows 4). Set aside: Envoy, a reverse proxy first, whose forward mode is less direct to set up and to log; a plane of its own; a router of the landing zone that only translates addresses.
