# Spec: a Kubernetes cluster for shared services

- **Status:** Proposed — its release is given in the README's [status](../../README.md#status); it depends on the Kubernetes day-to-day operations
- **Related:** [ADR-0002](../adr/0002-platform-kubernetes.md) (Kubernetes tenant), [ADR-0007](../adr/0007-monitoring.md) (monitoring by push), [ADR-0003](../adr/0003-scope-and-boundary.md) (projects), [ADR-0004](../adr/0004-planes-and-isolation.md) (planes, roles per plane), [integration points](../reference/integration-points.md)

## Problem

Shared services — a registry, a directory, an internal API, a metrics receiver, log collection — run in their own projects, joined to the planes with the role `shared` (ADR-0004). Many deployments want to run several of them on one Kubernetes cluster rather than one set of instances each.

The [Kubernetes tenant](../../stacks/tenants/kubernetes/README.md) cannot do it today. It is built as a consumer of the planes, with one flow per plane:

| Plane | Today | Admitted |
|---|---|---|
| publication | the ingress, reached by the entry point | the entry point only, PROXY v2 header expected |
| observability | the cluster's Prometheus pushes to the receiver | nothing comes in |
| internal services | the cluster consumes internal services | nothing comes in; `intranet_sources` describes the cluster as a client |

No other tenant can reach a service of the cluster: nothing is exposed on the internal services plane, and tenants have no route to each other on the publication plane.

## Goal

The same stack, deployed in a shared-services project, offers services to the tenants of a plane:

- HTTP(S) services: one route each (`HTTPRoute`) behind an internal entry of the cluster;
- TCP services (PostgreSQL, Redis, plain TCP): one exposed Service each;
- each service admitted to its consumers only, named in DNS, reachable in both plane modes;
- the cluster may also be the metrics receiver: the tenants push to it.

Out of scope: tenant workloads in the same cluster (a `shared` attachment reaches every tenant of its planes and is reached by them: mixing tenant workloads there would break the isolation the test checks); multi-tenancy inside a cluster.

## Design

### 1. Role per plane (configuration only)

The cluster's attachment in `shared/planes` takes the role `shared` on the planes where it offers services: for example `shared` on the internal services and observability planes, `tenant` on the publication plane. With the plane names of the scenario ([README](../../README.md#what-the-repository-contains)): `{ intranet = "shared", monitoring = "shared", svc_public = "tenant" }`. The transit router then routes the plane's tenants to the cluster and back. No change to `shared/planes`.

### 2. Exposed services, generic

The hard-coded ingress Service on the publication plane becomes one instance of a generic input (plane names of the scenario):

```hcl
exposed_services = {
  ingress    = { plane = "svc_public", ports = [80, 443], sources = "edge" }        # today's ingress
  receiver   = { plane = "monitoring", ports = [9090], sources = "tenants" }         # metrics receiver
  internal   = { plane = "intranet",   ports = [443],  sources = ["10.21.0.0/16"] } # internal Traefik entry
  postgres   = { plane = "intranet",   ports = [5432], sources = ["10.21.4.0/24"] }
}
```

For each one, the stack reserves the address (floating IP of the plane in gateway mode; fixed address of the cluster network, out of the allocation pool, in interface mode — as the ingress today), renders the Service (`loadBalancerIP`, `loadBalancerSourceRanges`, internal or floating-network annotations), outputs the address, and can write a DNS record.

### 3. An internal Traefik entry

A second Traefik entry point and Service on the plane where HTTP services are offered (the `internal` entry above): no PROXY protocol (its clients are tenants, not the entry point), TLS terminated by Traefik or passed through per route. Adding an HTTP service is then one `HTTPRoute`; restricting it to some consumers, an `IPAllowList` middleware on the route.

### 4. Sources, in both directions

- **Consumers → cluster.** `sources` lists the consumers' addresses: their range on an interface plane, their router's gateway address on an operator plane (each consumer's `<plane>_sources` output).
- **Cluster → consumers.** New outputs `<plane>_sources`: the cluster range on an interface plane, its router's address on an operator plane, for the consumers' admission rules when the cluster calls them. Monitoring needs none: the tenants push to the receiver ([ADR-0007](../adr/0007-monitoring.md)).

### 5. Consumers join the plane

The `vm` tenant joins the internal services plane as an optional plane, with the matching `<plane>_sources` output, as the Kubernetes tenant does ([certificates spec](tenant-certificates.md)). The `isolated` tenant does not join it today; it gets it the same way when it consumes a service.

### 6. Inside the cluster

The boundary between services is the cluster's: one namespace per service, default-deny network policies, ingress allowed from the internal Traefik entry or the service's own load balancer only. The stack ships the default-deny policy and documents the rest.

### 7. Isolation test

New rows: a declared consumer reaches its service; a tenant that is not a consumer does not; the cluster reaches no tenant; a pod of the cluster does not reach the tenants' bastions.

## Dependencies and order

1. Kubernetes day-to-day operations (upgrade, scaling, credential rotation, the duplicated add-on proxies after `clusterctl move`): a shared-services cluster is critical for every tenant.
2. Exposed services, generic (§2), with today's ingress migrated without change of address.
3. Internal entry and DNS (§3), consumer planes for `vm` and `isolated` (§5).
4. Receiver in the cluster (§4), network policies (§6), isolation rows (§7).

## Proposed decisions

1. **A separate stack, `stacks/shared/kubernetes`**, next to `stacks/tenants/kubernetes`, both on a common module `modules/kubernetes-cluster` extracted from today's stack (Cluster API manifests, bootstrap, add-ons, scripts). The layout already says the role; inputs, outputs and defaults differ (exposed services, default-deny policies, sources in both directions); a `role` input would fill one stack with conditions, and a single wrong value would expose a tenant cluster as a shared one. The extraction is checked like the building blocks were: identical plans before and after.
2. **TLS: an internal certificate authority by default** (cert-manager in the cluster), its root distributed to the consumers by cloud-init — the tenant stacks already render cloud-init, and it works for tenants without Internet access. Option documented: public certificates through an ACME DNS-01 challenge, when the names are under a public domain and the cluster reaches the Internet. Passthrough stays possible per route for services that manage their own TLS.
3. **Names: a DNS zone written by the shared-services stack only**, with the services' internal addresses. Designate has no per-network private view: the zone's records are visible to whoever resolves it, which exposes internal addresses but no access. Option documented: a resolver of the cluster (CoreDNS) exposed on the internal services plane, used by the consumers, for a zone that stays private.

## Open questions

- Which shared services the reference demonstrates in the cluster (a registry, a metrics receiver), and which stay documentation.
