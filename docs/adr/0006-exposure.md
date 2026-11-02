# ADR-0006: Exposure of the tenants

- **Status:** Proposed
- **Date:** 2026-11-02
- **Deciders:** Gregory Gabrielian
- **Supersedes, once accepted:** [ADR-0001](0001-reference-architecture.md) D2 for publication (a floating IP of the plane on every published instance) and D8 for the delivery of the routes. ADR-0001 D3 (one public entry point, SNI passthrough, PROXY protocol) is kept, with its purpose stated.

## Context

The Kubernetes tenant has always been exposed through one address: its ingress controller, behind a load balancer. **The exposure of a tenant of virtual machines was never designed as such.** The example tenant `web`, written without a load balancer, made an implicit choice: the entry point routes to each of its instances, and each instance carries a floating IP of `svc_public` in addition to its floating IP of `monitoring` (ADR-0001, D2). As a result, the entry point depends on the inside of the tenant (adding an instance changes the entry point), and an instance answers on two planes with one routing table: a floating IP only serves the sources routed back through its plane's router, and the setup was verified on OVN only.

**Publishing a domain replaces the entry point instances** (ADR-0001, D8): routes are written by cloud-init, which runs once. Measured in the tests: 5 to 8 minutes per change, requests lost during each replacement (8 of 179), and no host left on small clouds with strict anti-affinity (`No valid host was found`, 2026-10-29).

**The shared entry point answers a real need**, that of hosting providers ([profile B](../concepts/audiences.md#b-hosting-provider-or-managed-services-company)): many domains behind few public IPv4 addresses, TLS kept by each tenant. It is not the usual design across projects, where each project exposes itself with its own load balancer, which other readers ([profile A](../concepts/audiences.md#a-platform-team-on-a-public-or-sovereign-cloud)) may prefer.

## Options considered

**Exposure**

1. **The entry point routes to the tenants' instances.** Couples the entry point to every tenant.
2. **Each tenant exposes itself with its own public load balancer only.** The usual design; costs a public address and a load balancer per tenant, which profile B cannot afford for many small customers.
3. **Each tenant exposes one service address per domain, published through the shared entry point or through its own public address, chosen per tenant** (chosen).

**Delivery of the routes to the entry point**

1. **cloud-init, replacing the instances** (`v0.2.x`). Measured above.
2. **A file written by OpenTofu or Terraform over SSH** (`file` provisioner). Provisioners are a last resort in both tools; it needs a network path and a key from the deployer to the entry point, and it is configuration management, which ADR-0001 (D8) excluded.
3. **Object storage read by Traefik's HTTP provider.** Not every OpenStack cloud has object storage; the reference test cloud has none.
4. **A key-value store (Consul, etcd).** One more service to run and secure for a few dozen routes.
5. **Instance metadata, written in place by OpenTofu or Terraform through the Nova API and read by the instance** (chosen). The only channel from the stack to the instance that needs neither SSH nor another service.

**Certificates of the published domains** (TLS ends in the tenant)

1. **Octavia `TERMINATED_HTTPS` with certificates in Barbican.** The OpenStack-native pattern, but Octavia renews nothing (an external tool must push renewed certificates) and Barbican is not available on every cloud. Documented as an alternative.
2. **ACME with HTTP-01 challenges.** The entry point would forward port 80 per domain; a challenge may reach an instance that did not request it when a tenant runs several (Traefik's open-source edition does not share its ACME storage).
3. **ACME with DNS-01 challenges** (chosen).

## Decision

### D1 — A tenant exposes service addresses, never its instances

- For each domain it serves, a tenant exposes **one service address**: its Octavia load balancer when it runs several instances, or its instance when it has only one. The tenant stack outputs `domain → address:port` (`published_domains`).
- The entry point and every shared service know these addresses only: a tenant adds, removes or replaces instances without any change outside its project.
- On a plane with NAT, the service address is a floating IP of `svc_public` on the load balancer or the single instance; on a routed plane, its own address.
- The pattern inside a tenant of virtual machines mirrors the Kubernetes tenant: a TCP load balancer, then a reverse proxy or the application terminating TLS.

### D2 — Exposure chosen per tenant

- Each tenant either publishes its domains through the **shared entry point**, or exposes its service address with **its own public floating IP**. Both coexist in one account.
- The shared entry point stays as decided in ADR-0001 (D3), its purpose stated: many domains behind one public address and one load balancer, TLS kept by each tenant. Its limits are documented: a failure affects every tenant published through it; no WAF and no TLS termination, by design of passthrough; port 80 only redirects to HTTPS.

### D3 — Routes delivered in place through instance metadata

- The entry point stack writes each route as a metadata item of every Traefik instance: key `route-<domain>`, value the service address. Changing metadata updates the instances in place; they are never replaced for a route change.
- A systemd timer on each instance reads the metadata service, renders Traefik's dynamic configuration file and replaces it atomically; Traefik's file provider reloads it without dropping connections. An empty or unreadable answer leaves the current file untouched: a metadata service outage never removes routes.
- cloud-init keeps the static configuration (entry points, PROXY protocol, logs, metrics) and installs the timer; a change there still replaces the instances one at a time.
- `scripts/publish-domains.sh` gathers the tenants' outputs and applies the entry point stack; no replacement, no wait on the load balancer.
- Limits, documented: a metadata value holds 255 characters (one service address fits) and an instance 128 items by default (Nova quota `metadata_items`), hence about 120 domains per entry point. Routes hold no secret; they are readable by the project's members, as they were in `user_data`.

### D4 — At most one floating IP per address

No instance or load balancer carries floating IPs of several networks. Each plane is joined through its own router, and every flow on a plane is initiated from the side that holds the route back: the entry point to the service addresses on `svc_public`, the tenants to the metrics receiver on `monitoring` ([ADR-0007](0007-monitoring.md)), the tenants to the internal services on `intranet`.

### D5 — Certificates: ACME with DNS-01, in the tenant

- Each tenant obtains the certificates of its domains with ACME DNS-01 challenges on its own DNS zone: with Designate, an application credential scoped to the tenant's project and zone; elsewhere, the DNS provider's API (lego, used by Traefik and others, supports most providers).
- DNS-01 works whatever the number of instances, allows wildcard certificates and asks nothing of the entry point. HTTP-01 is not supported.
- Octavia with Barbican is documented as an alternative where Barbican is available, with its renewal caveat.

## Consequences

- **Breaking for `v0.2.x` users**, released as `v0.3.0` with a migration note: `published_domains` carries service addresses instead of backend lists; the floating IPs of `svc_public` on the instances go away. ADR-0001 gets the status *superseded in part by ADR-0006* when this ADR is accepted; its text is not edited.
- A tenant of several instances needs a load balancer, which the cloud bills; a single-instance tenant does not.
- The isolation test checks "entry point to service address" instead of "entry point to instance", and a new check publishes a domain while requests run and expects none lost.
- The module keeps `extra_floating_ips` (several floating IPs on one port is a Neutron capability); its documentation states the routing condition it relies on.
- To measure on the reference cloud: the delay before an updated metadata item is served to the instance (cache of the metadata service), hence the time to publish a domain.
