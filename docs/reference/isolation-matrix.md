# Isolation matrix

Every flow of the reference scenario between the Internet, the planes, the shared services and the tenants, with the expected result. Another deployment adds the rows of its own planes and services. The [isolation test](../guides/check-isolation.md) checks each row on a deployment ([`tests/isolation`](../../tests/isolation/README.md)); run it after every change. The rows that involve the published cluster or the internal services plane are checked when the test is given its kubeconfig; the rows of the certificates, when it is given the test ACME authority; the rows of the shared cluster (a Kubernetes cluster for shared services), when it is given that cluster's kubeconfig (`--shared-kubeconfig`).

*Enforced by* names the mechanism that makes the row true. The rows are the same whatever provides the planes ([ADR-0004](../adr/0004-planes-and-isolation.md)); the mechanism sometimes differs between planes with address translation (operator planes) and routed planes (hub planes, [How a tenant joins a plane](../concepts/plane-attachment.md)).

## The rules of every deployment

The rows `lz check` produces from the members of any deployment, the reference scenario included ([`lz`](../../tools/landing-zone/README.md), `landing_zone/isolation.py`). A source with no allowed row is a target only: its denied rows would prove nothing.

<!-- BEGIN_RULES: generated from tools/landing-zone/landing_zone/isolation.py, a unit test checks it is current -->

| From | To | Port | Expected | Enforced by |
|---|---|---|---|---|
| the Internet | the entry point's load balancer | 80, 443 | allowed | public floating IP |
| the Internet | a tenant's service address | 443 | denied | not routed from the Internet; load balancer sources (`allowed_cidrs`) = the entry point |
| the entry point | a tenant's service address (`vm` load balancer, Kubernetes ingress) | 443 | allowed | route to the publication plane; load balancer sources = the entry point (`edge_sources`) |
| the entry point | a tenant's instance, at its private address | 443 | denied | security group of the instances (source = their load balancer); with NAT, the address is also not routed on the plane: observed, not relied on |
| a tenant, a shared service or the entry point | another one's instances, at their private address | 22 and the ports they serve | denied | the security groups of the target admit only its load balancer, its bastion or the administrators, whatever routes a member adds |
| a tenant or a shared service | another tenant's service address | 443 | denied | load balancer sources = the entry point only |
| a consumer of a shared service | its services | their ports | allowed | route to the internal services plane; the service admits its consumers' `internal_sources` |
| any other member on the internal services plane, the entry point | a shared service's services | their ports | denied | the service admits only its consumers |
| the machine running the test | a shared service's services | their ports | denied | the service admits only its consumers |
| a member on the observability plane | the metrics receiver | its push port | allowed | route to the observability plane; security group of the receiver (sources = the plane, or the routed tenant ranges) |
| a member with `egress = "none"` | the Internet | 443 | denied | no egress router and no default route on its transit router (ADR-0016, D1) |

<!-- END_RULES -->

## The reference scenario

The checks the reference scenario adds, with its test fixtures and its clusters:

| From | To | Port | Expected | Enforced by |
|---|---|---|---|---|
| any instance, a pod of each cluster | IPv6: a global address or a default route | — | none | the reference creates no IPv6 subnet ([ADR-0015](../adr/0015-ipv6.md), D2) |
| the receiver, or anything on the observability plane | a tenant's metrics ports | 9100 | denied | security groups (no metrics rule); with NAT, the instances also have no address on the plane |
| the receiver | series of every tenant | — | present | agents push with `site`, `tenant`, `instance` labels |
| a tenant, or the entry point | the receiver | 22 | denied | security group of the receiver: SSH from the administrator addresses only |
| the receiver | a tenant's service address | 443 | denied | load balancer sources = entry point only |
| the receiver | the entry point's instances | 443 | denied | security group of the proxies (source = their load balancer); with NAT, the address is also not routed on the plane: observed, not relied on ([hostile route, gateway mode](test-procedure.md#hostile-route-gateway-mode)) |
| the receiver | an internal service | its port | denied | the service admits only its consumers |
| the receiver | the published cluster's ingress | 443 | denied | sources of the ingress = entry point only |
| the Kubernetes tenant | the bastions of the other stacks | 22 | denied | bastions admit the administrator addresses only |
| the receiver | the shared cluster's services | 443, 7000 | denied | load balancer sources = the consumers only; the receiver has no route to the plane |
| a pod of the shared cluster | a tenant's instances, service address and bastions | 443, 22 | denied | the cluster's role `shared` routes to the tenants of the plane, but their security groups and load balancers admit neither the plane nor the cluster |
| a pod of the shared cluster, in another namespace | the backends of a service | its port | denied | default-deny network policy of each service's namespace; ingress from the internal ingress or the service's own load balancer only |
| a user of either cluster | a Service of type `LoadBalancer` that is not an entry of the stack, or internal and open to sources outside the cluster network | - | refused | admission policy `load-balancer-entries`: the entries, in their namespace at the address the stack prepared, and internal load balancers whose sources are within the cluster network |
| a client trusting the authority | each published domain, through the entry point | 443 | certificate for the name, issued by the authority | the tenant's ACME client (lego, cert-manager) and DNS-01 ([ADR-0008](../adr/0008-tenant-certificates.md)) |
| a tenant, with its TSIG key | the `_acme-challenge` records of its own names | 53 | allowed | DNS server ACL: key, record type TXT, owner names, sources |
| a tenant, with its TSIG key | the `_acme-challenge` records of another tenant's names | 53 | denied | DNS server ACL: each key covers its tenant's names only |
| administrators | bastions, Kubernetes API | 22, 6443 | allowed | administration network; named administrator addresses only |
| every instance: entry point, tenants, receiver | a public name; for the tenants, also the zone of the landing zone (SOA), whose names they use | 53 | resolved | the resolvers of its subnet: Neutron's DHCP, or `dns_nameservers` ([ADR-0016](../adr/0016-network-services-and-edge-by-level.md), D3) |
| the private tenant | its resolver, behind the internal services plane | 53 | in use | `dns_nameservers` of the tenant; the resolver admits the sources of the plane only |
| the tenant with `egress = "shared"` | a declared name, through the shared egress | 80, 443 | allowed | the proxy's rules: the tenant, known by its source, and its names ([ADR-0016](../adr/0016-network-services-and-edge-by-level.md), D1) |
| the tenant with `egress = "shared"` | a name it did not declare, through the shared egress | 443 | refused (403) | the proxy's rules; every request is logged |
| the tenant with `egress = "shared"` | the Internet, directly | any | denied | no egress router and no default route on its transit router |
| the web and private tenants, not declared | the shared egress | its port | denied | the load balancer admits the declared tenants only (`allowed_cidrs`) |

The rows between shared services, and from a tenant to a shared service beyond its port, bound what a compromised shared service or tenant can reach ([lateral movement](../concepts/security.md#lateral-movement)).

The hostile-route case (a tenant routing to another through the transit router) and the spoofed-source case (a tenant sending with another address) change a tenant's router or port: they are steps of the [test procedure](test-procedure.md), not of the isolation test, which only opens TCP connections and reads the receiver. The hostile route is automated by [`tools/landing-zone`](../../tools/landing-zone/README.md) (step `hostile`, interface mode) and run by hand in gateway mode; the spoofed source is run by hand.

Address translation is not a boundary these rows rely on. A tenant can add a route on its own router, through the API, towards another tenant's range via that tenant's router address on a plane with NAT; whether the cloud forwards such a packet to the tenant's subnet depends on its network back end. The security groups of the targets decide, as on a routed plane.
