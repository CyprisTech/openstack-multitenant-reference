# Integration points

The architecture provides the infrastructure of sharing — the planes and the entry point — not the shared services themselves: your monitoring, your internal services and your DNS plug into the points below. For each point: where it is, which flows it opens, who is admitted, and what the stacks configure.

The components under `tests/fixtures` (a collector, an intranet service) only stand in for yours during the tests.

## Monitoring

| | |
|---|---|
| Plane | `monitoring` |
| Direction | Pull: your collector connects to the tenants |
| How targets are found | Each instance gets a floating IP of the monitoring plane and, when `monitoring.dns_zone` is set, an A record `<instance>` in that zone (DNS service discovery); the stacks also output their targets (`monitoring_targets`) |
| Ports | 9100 (node exporter) on every instance, 8082 (Traefik metrics) on the entry point; `monitoring.metrics_ports` adds others |
| Kubernetes tenant | Prometheus in the cluster, federated through a load balancer whose floating IP is created by the stack, with the record `<site>-platform-prometheus` (port 9090) |
| Admitted | Only `monitoring.collector_cidrs`: the collector's addresses as seen by the tenants. Tenants never reach each other's metrics |
| You provide | A Prometheus-compatible collector with an address on the monitoring plane, and outbound TCP to the metrics ports from its security groups |
| Checked by | The collector rows of the [isolation matrix](isolation-matrix.md) |

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

| | |
|---|---|
| Plane | `svc_public` |
| Direction | The entry point connects to the tenants' backends |
| Interface | Each tenant stack outputs `published_domains`: `{ "<domain>" = { backends = ["<address>:443", …] } }`; `scripts/publish-domains.sh` gathers them and applies the entry point |
| What reaches the backend | The TLS stream untouched (SNI passthrough), preceded by a PROXY protocol v2 header with the client address |
| Admitted | Backends accept HTTPS, and the PROXY header, only from the entry point's addresses on `svc_public`, read from its router (`<site>-edge-svc-public`) |
| Tenant provides | Backends that terminate TLS for their domains and accept PROXY protocol v2 |
| Checked by | The entry point rows of the [isolation matrix](isolation-matrix.md) |

## Administration

| | |
|---|---|
| Access | SSH to each tenant's bastion; the Kubernetes API on a floating IP of the administration network |
| Admitted | Only `admin.sources` and `bastion.ssh_cidrs`: specific operator addresses, never a whole plane range |
| Checked by | The administration rows of the [isolation matrix](isolation-matrix.md) |
