# Spec: network services and the edge, what remains

- **Status:** Proposed. Delivered in `v0.6` except the two parts below, whose release is given in the README's [status](../../README.md#status)
- **Related:** [ADR-0016](../adr/0016-network-services-and-edge-by-level.md) (network services and the edge, by level), [planes contract](../reference/planes-contract.md), [integration points](../reference/integration-points.md#name-resolution-time-and-package-mirrors)

## Delivered in v0.6

The design now lives in the documentation; this spec keeps what is not delivered.

| Part | Where it is described |
|---|---|
| Egress and exposure declared per tenant, the shared egress (ADR-0016, D1) | [architecture](../concepts/architecture.md#network-services), [`stacks/tenants/vm`](../../stacks/tenants/vm/README.md), [`stacks/shared/egress`](../../stacks/shared/egress/README.md) |
| Records in Designate or as an output, `dns_records` (D2) | [planes contract](../reference/planes-contract.md), the READMEs of the stacks |
| Recursive DNS and time as requirements on the cloud (D3) | [planes contract](../reference/planes-contract.md), [integration points](../reference/integration-points.md#name-resolution-time-and-package-mirrors) |
| The routes of the entry point as a reviewed input (D5) | [publish a domain](../guides/publish-a-domain.md), [`stacks/shared/entry-point`](../../stacks/shared/entry-point/README.md) |
| Rows of the isolation test: resolution, the resolver in use, the way out | [isolation matrix](../reference/isolation-matrix.md) |
| Name resolution inside the clusters (CoreDNS) | [architecture](../concepts/architecture.md#network-services), [`stacks/shared/kubernetes`](../../stacks/shared/kubernetes/README.md) |

## What remains

1. **A campaign on a cloud without Designate.** The public cloud profile ([ADR-0014](../adr/0014-profiles.md)) with `dns = "output"`, on a cloud whose projects can create the security groups the stacks need; the campaign checks that every stack applies and gives its `dns_records`. Waits for the quota of the public test cloud.
2. **Package mirrors and registry caches** (ADR-0016, D4), with the other integration points (`v0.8`): the integration point states the plane, the admission and the tenant inputs (a package mirror URL, registry mirrors for `containerd`); a test fixture stands in for them. With them, `egress = "none"` for the `kubernetes` stack, whose nodes then pull their images from the cache.

## Open questions

- The public cloud of the campaign: the provider planned, or another one with Octavia and without Designate.
