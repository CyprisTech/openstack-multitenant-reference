# Tear down

Order matters: what depends on another stack goes first.

**With [`lz`](../../tools/landing-zone/README.md):** `tools/landing-zone/lz teardown landing-zone.toml` runs the order below in waves (the clusters and the tenants, the shared services, the planes), then checks that nothing is left in the projects of its stacks. It destroys what its states hold, and nothing in a project of type `existing`, which it only attached.

By hand:

1. **Kubernetes clusters** (the published cluster, and the shared cluster): set `bootstrap = true` and apply (the bootstrap instance is needed again), admit it on the API, then run `delete-cluster.sh` on it — see [delete a cluster](kubernetes-lifecycle.md#delete-a-cluster).
2. **Services that admit named consumers**: the internal service (shared services project).
3. **Tenants**: `tofu destroy` in each tenant stack.
4. **Entry point**: `tofu destroy` in `stacks/shared/entry-point`.
5. **Services the tenants push to**: the receiver (shared services project).
6. **Planes** (hub planes): `tofu destroy` in `stacks/shared/planes`, last — Neutron refuses to remove a plane while a router of another project is still on it.
7. **Check that nothing is left** in each project: servers, volumes, load balancers, floating IPs, routers, networks, ports, security groups, server groups, DNS records. Delete the Kubernetes node image when you no longer need it.

Measured duration: about 9 minutes for the nine stacks of the test scenario, the published cluster included, then 1 min 30 for the leftover check ([test procedure](../reference/test-procedure.md#overview), 2026-11-21).
