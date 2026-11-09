# Isolation matrix

Every flow of the reference scenario between the Internet, the planes, the shared services and the tenants, with the expected result. Another deployment adds the rows of its own planes and services. The [isolation test](../guides/check-isolation.md) checks each row on a deployment ([`tests/isolation`](../../tests/isolation/README.md)); run it after every change. The rows that involve the Kubernetes tenant or the internal services plane are checked when the test is given its kubeconfig; the rows of the certificates, when it is given the test ACME authority; the rows of the cluster for shared services, when it is given that cluster's kubeconfig (`--shared-kubeconfig`).

*Enforced by* names the mechanism that makes the row true. The rows are the same whatever provides the planes ([ADR-0004](../adr/0004-planes-and-isolation.md)); the mechanism sometimes differs between planes with address translation (operator planes) and routed planes (hub planes, [How a tenant joins a plane](../concepts/plane-attachment.md)).

| From | To | Port | Expected | Enforced by |
|---|---|---|---|---|
| Internet | entry point load balancer | 80, 443 | allowed | public floating IP |
| Internet | a tenant's service address | 443 | denied | not routed from the Internet; load balancer sources (`allowed_cidrs`) = entry point |
| entry point | a tenant's service address (`vm` load balancer, Kubernetes ingress) | 443 | allowed | route to the publication plane; load balancer sources = entry point (`edge_sources`) |
| entry point | a tenant's instance, at its private address | 443 | denied | NAT plane: no route; routed plane: security group of the instances (source = their load balancer) |
| a tenant | another tenant's service address | 443 | denied | load balancer sources = entry point only |
| a tenant | another tenant, at its private address | any | denied | NAT plane: no route between tenants; routed plane: routes go to the shared services only, and the security groups of the target admit only its load balancer, its bastion or the administrators — also when a tenant adds a route to another through the transit router |
| a tenant | the metrics receiver | 9090 | allowed | route to the observability plane; security group of the receiver (sources = the plane, or the routed tenant ranges) |
| the receiver, or anything on the observability plane | a tenant's metrics ports | 9100 | denied | NAT plane: no address on the plane; routed plane: security groups (no metrics rule) |
| the receiver | series of every tenant | — | present | agents push with `site`, `tenant`, `instance` labels |
| a tenant, or the entry point | the receiver | 22 | denied | security group of the receiver: SSH from the administrator addresses only |
| the receiver | a tenant's service address | 443 | denied | load balancer sources = entry point only |
| the receiver | the entry point's instances | 443 | denied | NAT plane: no route; routed plane: security group of the proxies (source = their load balancer) |
| the Kubernetes tenant | an internal service | its port | allowed | router to the internal services plane; the service admits the tenant's `internal_sources` |
| `vm`, `isolated` | an internal service | its port | denied | `isolated` has no router to the internal services plane; a `vm` tenant joins it only when it consumes internal services, and the service admits only its consumers |
| the entry point, the receiver | an internal service | its port | denied | the service admits only its consumers |
| the receiver | the Kubernetes tenant's ingress | 443 | denied | sources of the ingress = entry point only |
| the Kubernetes tenant | the bastions of the other stacks | 22 | denied | bastions admit the administrator addresses only |
| a consumer (the `web` tenant) | the shared cluster's internal ingress and TCP service | 443, 7000 | allowed | route to the internal services plane; load balancer sources = the consumers' `internal_sources` |
| a tenant that is not a consumer, the entry point, the receiver, the Internet | the shared cluster's services | 443, 7000 | denied | load balancer sources = the consumers only; the entry point and the receiver have no route to the plane |
| a pod of the shared cluster | a tenant's instances, service address and bastions | 443, 22 | denied | the cluster's role `shared` routes to the tenants of the plane, but their security groups and load balancers admit neither the plane nor the cluster |
| a pod of the shared cluster, in another namespace | the backends of a service | its port | denied | default-deny network policy of each service's namespace; ingress from the internal ingress or the service's own load balancer only |
| a client trusting the authority | each published domain, through the entry point | 443 | certificate for the name, issued by the authority | the tenant's ACME client (lego, cert-manager) and DNS-01 ([ADR-0008](../adr/0008-tenant-certificates.md)) |
| a tenant, with its TSIG key | the `_acme-challenge` records of its own names | 53 | allowed | DNS server ACL: key, record type TXT, owner names, sources |
| a tenant, with its TSIG key | the `_acme-challenge` records of another tenant's names | 53 | denied | DNS server ACL: each key covers its tenant's names only |
| administrators | bastions, Kubernetes API | 22, 6443 | allowed | administration network; named administrator addresses only |
| `isolated` | the Internet | any | denied | no egress router: its only router joins the observability plane |

The rows between shared services, and from a tenant to a shared service beyond its port, bound what a compromised shared service or tenant can reach ([lateral movement](../concepts/architecture.md#lateral-movement)).

The hostile-route case (a tenant routing to another through the transit router) and the spoofed-source case (a tenant sending with another address) change a tenant's router or port: they are steps of the [test procedure](test-procedure.md), not of the automatic test, which only opens TCP connections and reads the receiver.
