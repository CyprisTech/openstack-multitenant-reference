# Sizing and limits

What a deployment needs, what it shares, and how far it scales.

## What you deploy, what we test

**A deployment** has one project per role ([ADR-0003](../adr/0003-scope-and-boundary.md)), and only the roles it needs. The smallest useful one is three or four projects: the hub of the planes (none when the operator provides them), the entry point if the tenants share one, and one project per tenant. The shared egress, the shared cluster and the internal services are added when they are needed.

**The test campaign** deploys more, because what it proves is the isolation between projects, and each role in its own project ([test procedure](test-procedure.md)): every stack, both tenant types and the private tenant, and test fixtures that stand in for services your organisation already runs, the metrics receiver, the certificate authority and its DNS, a resolver behind a plane and an internal service. You do not deploy the fixtures. In 2026-11, the private cloud scenario uses nine projects; what you run on your own deployment is the [isolation test](../guides/check-isolation.md), against the projects you have.

## Sizing

What the test campaigns of 2026-11-19 ran, project by project, with the flavors of the test cloud ([campaign sizing](../../tests/campaign/README.md#sizing)); every instance boots from the flavor's local disk. The Kubernetes clusters are deployed one after the other in the tests; in production both run at once, and a published cluster usually has 3 control plane nodes.

| Project | Instances | vCPU | RAM | Load balancers | Floating IPs |
|---|---|---|---|---|---|
| entry point | 2 | 2 | 2 GiB | 1 | 1 public |
| `vm` tenant | 2 | 2 | 2 GiB | 1 | 1 on the publication plane with an operator plane with NAT, none otherwise |
| `kubernetes` tenant | 3 (1 control plane, 2 workers) | 6 | 12 GiB | 2 (API, ingress) | 1 administration (API), 1 on the publication plane with NAT |
| shared cluster | 5 (3 control plane, 2 workers) | 10 | 20 GiB | 3 (API, internal ingress, TCP service) | 1 administration (API), 2 on the internal services plane with NAT |
| bootstrap of a cluster (temporary) | 1 | 2 | 4 GiB | 0 | 1 administration |
| `vm` tenant, private | 1 | 1 | 1 GiB | 0 | 0 |
| shared services: receiver | 1 | 2 | 2 GiB | 0 | 1 on the observability plane with NAT |
| shared services: internal service, ACME authority, resolver (tests) | 3 | 3 | 3 GiB | 0 | 1 each on the internal services plane with NAT |
| shared egress | 2 | 2 | 2 GiB | 1 | 1 on the internal services plane with NAT |
| `vm` tenant with the shared egress (tests) | 1 | 1 | 1 GiB | 0 | 0 |
| bastions (one per stack, optional) | 1 each | 1 each | 1 GiB each | 0 | 1 each, administration |
| **Total, both clusters, without bastions and bootstrap** | **16** | **25** | **41 GiB** | **7** | **up to 10** |
| **Peak of a test campaign** (2026-11-21, measured on the test cloud during the upgrade of the shared cluster: one cluster at a time, with the bastions, a bootstrap instance and the extra machine of the rolling upgrade) | **20** | **29** | **43 GiB** | | |

**Load balancers cost instances too.** With the `ACTIVE_STANDBY` topology, each load balancer runs two amphorae, in the cloud operator's Octavia project and on the same hypervisors: 14 more instances for the 7 load balancers above, of the operator's amphora flavor. On a small cloud they are what runs out first: they caused some of the "no valid host" failures seen in the tests.

With hub planes, the hub project holds one router per plane and no instance.

## Single points of failure

**Status:** delivered; the behaviour on a failure is the cloud's (Neutron, Octavia).

| Component | Shared by | Redundancy | On its loss |
|---|---|---|---|
| Entry point | every tenant published through it | two Traefik instances in anti-affinity; the load balancer active/standby where the cloud offers it | the published domains stop answering; tenants exposed directly are not affected |
| Hub project and its transit router | every project on hub planes | the router's high availability is Neutron's (OVN gateway chassis, L3 HA) | the planes stop routing between projects; each project keeps its own egress |
| A tenant's transit router | the tenant | as above | the tenant loses its planes and its egress |
| Receiver, internal services | their consumers | yours: they are integration points | metrics are not stored; the consumers of the service lose it |
| Shared egress | the tenants with `egress = "shared"` | two Squid instances in anti-affinity behind the load balancer | those tenants lose their way out; the others are not affected |
| Kubernetes API | the cluster's administration | the CAPO load balancer, active/standby where offered; 3 control plane nodes | the cluster runs, but cannot be changed |
| Bastions | the administration of their stack | one per stack | administrators lose SSH to that stack; workloads are not affected |

## Scale limits

**Status:** delivered; measured or documented by the providers.

| Limit | Value | Beyond it |
|---|---|---|
| Domains per entry point | about 120 (Nova quota `metadata_items`, 128 by default) | several entry points, or a quota raised by the operator ([trade-offs](../concepts/trade-offs.md#16-routes-through-instance-metadata)) |
| Routers per project | one per plane joined, one transit router, one egress router, one for a bastion on its own network | raise the router quota, or place the bastion on the stack's network (public cloud profile: 4 at most) |
| Projects on a plane | one router address per attachment in the plane's range | a larger plane range |
| Routes of a transit router | Neutron's `max_routes`, 30 by default: about 30 attachments per plane | a quota raised by the operator, or aggregates of tenant ranges |
| Admission rules | one security group rule per declared source and port | aggregates of tenant ranges (`tenant_ranges`), which the shared services admit as a whole |
| Load balancers | each one runs two amphorae in the operator's project | the operator's capacity for amphorae ([sizing](#sizing)) |
