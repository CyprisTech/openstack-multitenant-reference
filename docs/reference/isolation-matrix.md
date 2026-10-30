# Isolation matrix

Every flow between the Internet, the shared planes and the tenants, with the expected result. The [isolation test](../guides/check-isolation.md) checks each row on a deployment; run it after every change.

Each row is checked by the acceptance test ([`tests/isolation`](../../tests/isolation/README.md)) after deployment; the rows that involve `platform` or the `intranet` plane are checked when the test is given the platform kubeconfig. *Enforced by* names the mechanism that makes the row true.

| From | To | Port | Expected | Enforced by |
|---|---|---|---|---|
| Internet | edge load balancer | 80, 443 | allowed | public floating IP, security group |
| Internet | `web`, `platform`, `isolated` | any | denied | no public address |
| edge Traefik | `web` VMs | 443 | allowed | `svc_public` route, security group |
| edge Traefik | `platform` ingress | 443 | allowed | `svc_public` route, security group |
| `web` | `platform` ingress | 443 | denied | security group (source = edge only) |
| `platform` | `intranet` | any | allowed | router to `intranet` |
| `web` | `intranet` | any | denied | no router to `intranet` |
| `isolated` | `web`, `platform`, `edge` | any | denied | no route |
| Collector | every instance, through its `monitoring` floating IP | metrics ports | allowed | floating IP of `monitoring`, route to the plane range, security group (source = `collector_cidrs`) |
| Any tenant | another tenant, through `monitoring` floating IPs | metrics ports | denied | security group (source = `collector_cidrs` only: every tenant reaches the plane with an address of its range, through source NAT) |
| `isolated` | the Internet | any | denied | no egress router |
