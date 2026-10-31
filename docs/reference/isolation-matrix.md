# Isolation matrix

Every flow between the Internet, the shared planes and the tenants, with the expected result. The [isolation test](../guides/check-isolation.md) checks each row on a deployment; run it after every change.

Each row is checked by the acceptance test ([`tests/isolation`](../../tests/isolation/README.md)) after deployment; the rows that involve `platform` or the `intranet` plane are checked when the test is given the platform kubeconfig. *Enforced by* names the mechanism that makes the row true, for planes provided by the operator (gateway mode) and for shared private planes with a transit router (interface mode, [How a tenant joins a plane](../concepts/plane-attachment.md)). The rows are the same in both modes.

| From | To | Port | Expected | Enforced by |
|---|---|---|---|---|
| Internet | edge load balancer | 80, 443 | allowed | public floating IP, security group |
| Internet | `web`, `platform`, `isolated` | any | denied | no public address |
| edge Traefik | `web` VMs | 443 | allowed | route to `svc_public` (gateway: floating IP of the VM; interface: through the transit router), security group |
| edge Traefik | `platform` ingress | 443 | allowed | same as above, to the ingress address, security group |
| `web` | `platform` ingress | 443 | denied | security group (source = edge only) |
| `platform` | `intranet` | any | allowed | router to `intranet` |
| `web` | `intranet` | any | denied | no router to `intranet` |
| `isolated` | `web`, `platform`, `edge` | any | denied | no route |
| Any tenant | another tenant, at its private address | any | denied | gateway: no route between tenants; interface: routes go to shared services only, and the security groups of the target admit only the edge, the collector or the operators — also when a tenant adds a route to another through the transit router (its own router is under its control) |
| Collector | every instance, at its `monitoring` address | metrics ports | allowed | gateway: floating IP of `monitoring`; interface: own address, through the transit router; security group (source = `collector_cidrs`) |
| Any tenant | another tenant, at its `monitoring` address | metrics ports | denied | security group (source = `collector_cidrs` only) |
| `isolated` | the Internet | any | denied | no egress router |

The hostile-route case (a tenant routing to another through the transit router) needs a change of a tenant's router: it is a step of the [test procedure](test-procedure.md), not of the automatic test, which only opens TCP connections.
