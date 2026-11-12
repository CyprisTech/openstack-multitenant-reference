# Tear down

Order matters: what depends on another stack goes first.

1. **Kubernetes clusters** (the published cluster, and the shared cluster): set `bootstrap = true` and apply (the bootstrap instance is needed again), admit it on the API, then run `delete-cluster.sh` on it — see [its README](../../stacks/tenants/kubernetes/README.md#teardown).
2. **Services that admit named consumers**: the internal service (shared services project).
3. **Tenants**: `tofu destroy` in each tenant stack.
4. **Entry point**: `tofu destroy` in `stacks/shared/entry-point`.
5. **Services the tenants push to**: the receiver (shared services project).
6. **Planes** (hub planes): `tofu destroy` in `stacks/shared/planes`, last — Neutron refuses to remove a plane while a router of another project is still on it.
7. **Check that nothing is left** in each project: servers, volumes, load balancers, floating IPs, routers, networks, ports, security groups, server groups, DNS records. Delete the Kubernetes node image when you no longer need it.

Measured durations: 4 to 7 minutes for a Kubernetes cluster, about 7 for the stacks ([test procedure](../reference/test-procedure.md#10-teardown)).
