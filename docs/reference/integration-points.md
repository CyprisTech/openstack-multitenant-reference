# Integration points

The architecture provides the infrastructure of sharing — the planes and the entry point — not the platform services themselves: your observability, internal services, backups and secrets plug into the points below. Plane names are those of the reference scenario. For each point: where it is, which flows it opens, who is admitted, and what the stacks configure.

The components under `tests/fixtures` (a metrics receiver, an internal service) only stand in for yours during the tests ([ADR-0003](../adr/0003-scope-and-boundary.md), D4).

## Observability: metrics

The contract is [ADR-0007](../adr/0007-monitoring.md); the receiver is yours.

| | |
|---|---|
| Plane | `observability` |
| Direction | Push: the tenants connect to your receiver; nothing on the plane connects into a tenant |
| Protocol | Prometheus remote write at `<receiver>/api/v1/write`; OTLP at `<receiver>/api/v1/otlp/v1/metrics` for workloads that use it |
| In the tenants | The `vm` instances and the entry point run their exporters and a Prometheus agent ([`modules/metrics-agent`](../../modules/metrics-agent/README.md)); the published cluster's Prometheus pushes with remote write; the `isolated` stand-in workload pushes OTLP |
| Identification | Labels `site`, `tenant` and `instance` on every series; with address translation, addresses do not identify the sources |
| Configured by | The input `monitoring.receiver` of every stack: the receiver's base URL |
| You provide | A receiver in a project of shared services, attached to `observability` with the role `shared`, admitting the plane (operator plane) or the tenant ranges routed to it (hub plane) on its port; the alerts on missing series |
| Checked by | The monitoring rows of the [isolation matrix](isolation-matrix.md): every tenant reaches the receiver, the receiver holds series from every tenant, nothing reaches a tenant's metrics ports |

## Internal services

| | |
|---|---|
| Plane | `internal` |
| Direction | Tenants connect to internal services published on the plane (registry, database, directory…) |
| Who joins | Only the tenants that need it; in the scenario, the Kubernetes tenant and the `vm` tenant |
| Admitted | Each internal service admits the addresses of the tenants allowed to use it, output by the tenant stack (`internal_sources`): the tenant's router address on an operator plane with address translation, the tenant's range on a hub plane |
| You provide | The services and their admission rules |
| Checked by | The internal service rows of the [isolation matrix](isolation-matrix.md): the Kubernetes tenant reaches the service, the other tenants do not |

## Users of internal services

People, not tenants, using a service on the internal services plane.

| | |
|---|---|
| Operator plane | The corporate network or the VPN is already routed to this external network |
| Hub plane | No route from outside: a VPN gateway you provide, attached to the plane with the role `shared` |
| Admitted | The range of the VPN or corporate network, as the service sees it. Not the administration path: a user is not an administrator |
| You provide | The VPN or the corporate route, and the authentication of the users: network admission lets a whole range in and identifies nobody |

## Publication through the entry point

The design is [ADR-0006](../adr/0006-exposure.md).

| | |
|---|---|
| Plane | `publication` |
| Direction | The entry point connects to each tenant's service address |
| Interface | Each tenant stack outputs `published_domains`: `{ "<domain>" = { backends = ["<service address>:443"] } }`; `scripts/publish-domains.sh` gathers them and applies the entry point, whose instances read their routes from their metadata |
| What reaches the tenant | The TLS stream untouched (SNI passthrough), preceded by a PROXY protocol v2 header with the client address |
| Admitted | The service address accepts connections only from the entry point's addresses on the publication plane (output `publication_sources`, input `edge_sources` of the tenants) |
| Tenant provides | A service address per domain (its load balancer, or its only instance), and backends that terminate TLS with certificates obtained by ACME DNS-01 on its own zone, and accept PROXY protocol v2 |
| Instead | A tenant may expose its service address with its own floating IP of `egress_network` (`exposure = "public"` in the stacks `tenants/vm` and `tenants/kubernetes`): the entry point is not used and the tenant does not join the publication plane. The `vm` load balancer then sends the PROXY v2 header itself; the ingress of the published cluster receives none |
| Checked by | The publication rows of the [isolation matrix](isolation-matrix.md) |

## Administration

| | |
|---|---|
| Access | SSH to each tenant's bastion; the Kubernetes API on a floating IP of the administration network |
| Admitted | Only `admin.sources` and `bastion.ssh_cidrs`: specific administrator addresses, never a whole plane range |
| Checked by | The administration rows of the [isolation matrix](isolation-matrix.md) |

## Observability: logs and audit events

| | |
|---|---|
| Plane | `observability` |
| Direction | Push, as for metrics: an agent next to the source sends to your log store; nothing connects into a project |
| Content | System and service logs of every instance; audit events of the administration paths (bastions, Kubernetes API) |
| Identification | Labels `site`, `tenant`, `instance` |
| You provide | A log store in a project of shared services, role `shared` on the plane |

## Backups of tenant data

| | |
|---|---|
| Plane | a plane dedicated to backups, or `observability` when the volume is small |
| Direction | Push: each tenant sends its backups to your backup store; restores are pulled by the tenant |
| Scope | Tenant data (volumes, databases, Kubernetes resources); the architecture itself is rebuilt from code |
| You provide | A backup store in a project of shared services, role `shared` on the plane, with its retention and encryption |

## Secrets

| | |
|---|---|
| Plane | `internal` |
| Direction | Tenants read their secrets from your secret store; nothing is written in instance metadata or `user_data` |
| You provide | A secret store in a project of shared services, admitting each tenant to its own secrets only |

## Name resolution, time and package mirrors

| | |
|---|---|
| Plane | `internal`, or a plane of their own |
| Direction | Tenants query the resolvers, time servers and mirrors; the tenants' subnets point to them |
| Provided by | The architecture, as level 2 network services ([ADR-0003](../adr/0003-scope-and-boundary.md), D4), or the cloud operator ([network services](../concepts/architecture.md#network-services)) |
| Reflection | Name resolution and time answer on UDP: a project able to send spoofed sources can use them for reflection ([lateral movement](../concepts/architecture.md#lateral-movement)) |

## Automation: a GitOps pipeline

| | |
|---|---|
| Where | Outside the cloud's planes: a pipeline that plans each stack, waits for a review, and applies, with one credential per stack and project |
| You provide | The pipeline tool and the state backend, itself backed up ([resilience](../concepts/architecture.md#resilience-and-continuity)) |
