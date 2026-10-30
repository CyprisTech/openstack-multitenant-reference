# Tear down

Order matters: what depends on another stack goes first.

1. **Kubernetes tenants**: set `bootstrap = true` and apply (the bootstrap instance is needed again), admit it on the API, then run `delete-cluster.sh` on it — see [its README](../../stacks/tenants/kubernetes/README.md#teardown).
2. **Test fixtures**, if any: the intranet service first (it reads the Kubernetes tenant's router), then the collector.
3. **Tenants**: `tofu destroy` in each tenant stack.
4. **Entry point**: `tofu destroy` in `stacks/shared/entry-point`.
5. **Check that nothing is left** in each project: servers, volumes, load balancers, floating IPs, routers, networks, ports, security groups, server groups, DNS records. Delete the Kubernetes node image when you no longer need it.

Measured durations: about 5 minutes for a Kubernetes cluster, 6 for the stacks ([test procedure](../reference/test-procedure.md#8-teardown)).
