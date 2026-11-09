# ADR-0010: A Kubernetes cluster for shared services

- **Status:** Accepted
- **Date:** 2026-11-08
- **Deciders:** maintainers
- **Refines:** [ADR-0002](0002-platform-kubernetes.md) (Kubernetes cluster), [ADR-0006](0006-exposure.md) (exposure), [ADR-0008](0008-tenant-certificates.md) (certificates). Design details: [spec](../specs/kubernetes-shared-services.md).

## Context

Shared services run in their own projects, attached to the planes with the role `shared`. Many deployments want several of them on one Kubernetes cluster. The Kubernetes tenant is built as a consumer of the planes: nothing can reach a service of the cluster from another tenant.

## Options considered

1. **A `role` input on the tenant stack** — one stack full of conditions, and a single wrong value exposes a tenant cluster as a shared one.
2. **A separate stack on a common module** — the layout states the role; inputs, outputs and defaults differ. Chosen.

## Decision

### D1 — A separate stack on a common module

`stacks/shared/kubernetes` and `stacks/tenants/kubernetes` both call `modules/kubernetes-cluster`. The module takes the planes the cluster joins and its entries: `ingresses` and layer 4 `services`, each at an address prepared by the stack.

### D2 — One ingress per audience

Each ingress has its own Traefik deployment, Gateway and Service. With one Traefik for both audiences, a route attached to the wrong listener would publish an internal service on the Internet. The shared cluster is not published; a cluster for published applications is another cluster.

### D3 — Certificates and names go through the organisation's services

Certificates come from the organisation's ACME authority through cert-manager, as for the tenants ([ADR-0008](0008-tenant-certificates.md)). The consumers trust its root. The names of the services are records of a zone of the internal names. The stack writes them when the cloud has Designate and the zone is owned by or shared with its project: the names follow the addresses without a manual step. Otherwise the stack outputs them for the organisation's DNS provider. The certificates keep the DNS provider of ADR-0008, since public zones are rarely in Designate.

### D4 — The boundary between services is the cluster's

One namespace per service and a default-deny network policy; ingress from the internal ingress or the service's own load balancer only.

## Consequences

- The reference demonstrates an HTTP and a TCP service, not operated; real products are level 3 ([ADR-0003](0003-scope-and-boundary.md), D4).
- A shared cluster is reached by every tenant of its plane and reaches them: their admission rules are the barrier.
