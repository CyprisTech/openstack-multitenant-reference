# Add a tenant

A tenant is a project of the account with its own credentials, joined to the shared planes it needs through its own routers.

1. **Create the project** in the account (provider's console or API, or cloud-baseline on a private cloud) and an application credential scoped to it (`member`, plus `load-balancer_member` for a load balancer). Add it to `clouds.yaml`.
2. **Choose the tenant type**: [`vm`](../../stacks/tenants/vm/README.md) (instances published through the entry point), [`isolated`](../../stacks/tenants/isolated/README.md) (no public exposure) or [`kubernetes`](../../stacks/tenants/kubernetes/README.md).
3. **Copy the stack configuration** for the new tenant — a new working directory or a new state key per tenant — and set:
   - `cloud`: the new `clouds.yaml` entry;
   - `site`: the same as the other stacks;
   - the address range of the tenant network, outside every other tenant's range and the ranges reserved by the [planes contract](../reference/planes-contract.md);
   - `monitoring.collector_cidrs`: your collector's addresses.
4. `tofu init && tofu apply`, then `tofu plan` must be empty.
5. If the tenant serves domains, [publish them](publish-a-domain.md).
6. [Check the isolation](check-isolation.md): the new tenant must reach only what its type allows.
