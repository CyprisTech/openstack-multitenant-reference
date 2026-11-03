# Isolation matrix

Every flow between the Internet, the planes, the shared services and the tenants, with the expected result. The [isolation test](../guides/check-isolation.md) checks each row on a deployment ([`tests/isolation`](../../tests/isolation/README.md)); run it after every change. The rows that involve the Kubernetes tenant or the `intranet` plane are checked when the test is given its kubeconfig.

*Enforced by* names the mechanism that makes the row true. The rows are the same whatever provides the planes ([ADR-0004](../adr/0004-planes-and-isolation.md)); the mechanism sometimes differs between planes with address translation (operator planes) and routed planes (hub planes, [How a tenant joins a plane](../concepts/plane-attachment.md)).

| From | To | Port | Expected | Enforced by |
|---|---|---|---|---|
| Internet | entry point load balancer | 80, 443 | allowed | public floating IP |
| Internet | a tenant's service address | 443 | denied | not routed from the Internet; load balancer sources (`allowed_cidrs`) = entry point |
| entry point | a tenant's service address (`vm` load balancer, Kubernetes ingress) | 443 | allowed | route to `svc_public`; load balancer sources = entry point (`edge_sources`) |
| entry point | a tenant's instance, at its private address | 443 | denied | NAT plane: no route; routed plane: security group of the instances (source = their load balancer) |
| a tenant | another tenant's service address | 443 | denied | load balancer sources = entry point only |
| a tenant | another tenant, at its private address | any | denied | NAT plane: no route between tenants; routed plane: routes go to the shared services only, and the security groups of the target admit only its load balancer, its bastion or the operators — also when a tenant adds a route to another through the transit router |
| a tenant | the metrics receiver | 9090 | allowed | route to `monitoring`; security group of the receiver (sources = the plane, or the routed tenant ranges) |
| the receiver, or anything on `monitoring` | a tenant's metrics ports | 9100 | denied | NAT plane: no address on the plane; routed plane: security groups (no metrics rule) |
| the receiver | series of every tenant | — | present | agents push with `site`, `tenant`, `instance` labels |
| the Kubernetes tenant | an internal service on `intranet` | its port | allowed | router to `intranet`; the service admits the tenant's `intranet_sources` |
| `vm`, `isolated` | an internal service on `intranet` | its port | denied | no router to `intranet`; the service admits only its consumers |
| the Kubernetes tenant | the bastions of the other stacks | 22 | denied | bastions admit the operator addresses only |
| operators | bastions, Kubernetes API | 22, 6443 | allowed | administration network; named operator addresses only |
| `isolated` | the Internet | any | denied | no egress router: its only router joins `monitoring` |

The hostile-route case (a tenant routing to another through the transit router) needs a change of a tenant's router: it is a step of the [test procedure](test-procedure.md), not of the automatic test, which only opens TCP connections and reads the receiver.
