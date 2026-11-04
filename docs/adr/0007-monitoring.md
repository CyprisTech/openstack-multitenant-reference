# ADR-0007: Observability as a push integration point

- **Status:** Accepted (implemented in v0.3.0); supersedes [ADR-0001](0001-reference-architecture.md) D2 and [ADR-0002](0002-platform-kubernetes.md) D5 for monitoring
- **Date:** 2026-11-02
- **Deciders:** Gregory Gabrielian
- **Supersedes, once accepted:** [ADR-0001](0001-reference-architecture.md) D2 for monitoring (a floating IP of `monitoring` per instance, targets discovered by DNS); [ADR-0002](0002-platform-kubernetes.md) D5 for monitoring (federation of the cluster's Prometheus through a load balancer)

## Context

Monitoring is the first platform service to fit the boundary of [ADR-0003](0003-scope-and-boundary.md) (D4): the reference states the contract, the tools are the deployer's.

In `v0.2.x` the contract is pull: a central collector connects to every tenant, its addresses are admitted on every metrics port, each instance carries a floating IP and a DNS record on the `monitoring` plane, and the Kubernetes tenant's Prometheus is federated through a load balancer. Pull is how Prometheus works and stays the common practice inside one network or cluster. Across tenant boundaries, the common practice is the reverse: an agent next to the targets reads them locally and pushes to a central store (Prometheus remote write), which also removes every inbound monitoring flow into the tenants.

## Options considered

1. **Keep the pull contract.** Needs a path from the collector into every tenant, hence a floating IP of `monitoring` on every instance with operator planes.
2. **Federation of per-tenant Prometheus servers.** Pull again, across the boundary; advised for small volumes only.
3. **Push: an agent in each tenant writes to a receiver of the shared services** (chosen).

**Agent**: Prometheus in agent mode, or the OpenTelemetry Collector. OpenTelemetry leads for traces and is growing for logs; for metrics, Prometheus remains the reference and continues the exporters already deployed. The contract (remote write) does not depend on the agent.

## Decision

### D1 — Contract

- The deployer runs a **receiver of the Prometheus remote-write protocol** (Prometheus, Mimir, Thanos, VictoriaMetrics and others accept it) in a project of shared services, joined to `monitoring` with the role `shared`.
- The `monitoring` plane carries **one flow: from the tenants to the receiver's address and port**. Nothing on the plane connects into a tenant.
- The receiver's address and port are an input of every tenant stack.

### D2 — In the tenants: Prometheus in agent mode

- Each instance runs its exporters and **Prometheus in agent mode**, which reads them locally and pushes to the receiver. The Kubernetes tenant's Prometheus pushes the same way.
- Series are identified by labels (site, tenant, instance), not by addresses.
- Workloads instrumented with OpenTelemetry push OTLP, which the receiver also accepts; the stand-in workload of the `isolated` tenant does.
- Logs and audit events follow the same pattern; the agent may then be one for all three, chosen with that integration point.

### D3 — Detecting a silent target

A target that stops pushing is detected by the receiver (alert on missing series), as the `up` metric does with pull. The rules are the receiver's, outside the reference.

### D4 — Removed

- The collector's addresses admitted on the metrics ports (`collector_cidrs`).
- The floating IPs and DNS records of the `monitoring` plane on the instances.
- The federation load balancer of the Kubernetes tenant.

## Consequences

- **Breaking for `v0.2.x` users**, released as `v0.3.0` with a migration note: monitoring moves from pull to push. ADR-0001 and ADR-0002 get the status *superseded in part by ADR-0007* when this ADR is accepted; their text is not edited.
- The test fixture under `tests/fixtures` becomes a receiver. The isolation test checks the new flows: tenants reach the receiver; nothing on the plane reaches a tenant's metrics ports.
- With operator planes and NAT, the receiver sees the tenant router's address: identification relies on the labels.
