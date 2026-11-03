# Integration points

The architecture provides the infrastructure of sharing — the planes and the entry point — not the shared services themselves: your monitoring, your internal services and your DNS plug into the points below. For each point: where it is, which flows it opens, who is admitted, and what the stacks configure.

The components under `tests/fixtures` (a metrics receiver, an intranet service) only stand in for yours during the tests ([ADR-0003](../adr/0003-scope-and-boundary.md), D4).

## Monitoring

The contract is [ADR-0007](../adr/0007-monitoring.md); the receiver is yours.

| | |
|---|---|
| Plane | `monitoring` |
| Direction | Push: the tenants connect to your receiver; nothing on the plane connects into a tenant |
| Protocol | Prometheus remote write at `<receiver>/api/v1/write`; OTLP at `<receiver>/api/v1/otlp/v1/metrics` for workloads that use it |
| In the tenants | The `vm` instances and the entry point run their exporters and a Prometheus agent ([`modules/metrics-agent`](../../modules/metrics-agent/README.md)); the Kubernetes tenant's Prometheus pushes with remote write; the `isolated` stand-in workload pushes OTLP |
| Identification | Labels `site`, `tenant` and `instance` on every series; with address translation, addresses do not identify the sources |
| Configured by | The input `monitoring.receiver` of every stack: the receiver's base URL |
| You provide | A receiver in a project of shared services, attached to `monitoring` with the role `shared`, admitting the plane (operator plane) or the tenant ranges routed to it (hub plane) on its port; the alerts on missing series |
| Checked by | The monitoring rows of the [isolation matrix](isolation-matrix.md): every tenant reaches the receiver, the receiver holds series from every tenant, nothing reaches a tenant's metrics ports |

## Intranet

| | |
|---|---|
| Plane | `intranet` |
| Direction | Tenants connect to internal services published on the plane (registry, database, directory…) |
| Who joins | Only the tenants that need it; today the Kubernetes tenant |
| Admitted | Each internal service admits the addresses of the tenants allowed to use it: with planes provided by the operator, the address of the tenant's intranet router (source NAT), output by the tenant stack |
| You provide | The services and their admission rules |
| Checked by | The intranet rows of the [isolation matrix](isolation-matrix.md): the Kubernetes tenant reaches the service, the other tenants do not |

## Publication through the entry point

The design is [ADR-0006](../adr/0006-exposure.md).

| | |
|---|---|
| Plane | `svc_public` |
| Direction | The entry point connects to each tenant's service address |
| Interface | Each tenant stack outputs `published_domains`: `{ "<domain>" = { backends = ["<service address>:443"] } }`; `scripts/publish-domains.sh` gathers them and applies the entry point, whose instances read their routes from their metadata |
| What reaches the tenant | The TLS stream untouched (SNI passthrough), preceded by a PROXY protocol v2 header with the client address |
| Admitted | The service address accepts connections only from the entry point's addresses on `svc_public` (output `svc_public_sources`, input `edge_sources` of the tenants) |
| Tenant provides | A service address per domain (its load balancer, or its only instance), and backends that terminate TLS with certificates obtained by ACME DNS-01 on its own zone, and accept PROXY protocol v2 |
| Instead | A tenant may expose its service address with its own public floating IP (`exposure = "public"` in the `vm` stack): the entry point is not used |
| Checked by | The publication rows of the [isolation matrix](isolation-matrix.md) |

## Administration

| | |
|---|---|
| Access | SSH to each tenant's bastion; the Kubernetes API on a floating IP of the administration network |
| Admitted | Only `admin.sources` and `bastion.ssh_cidrs`: specific operator addresses, never a whole plane range |
| Checked by | The administration rows of the [isolation matrix](isolation-matrix.md) |
