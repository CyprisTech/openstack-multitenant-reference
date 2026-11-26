# Upgrade to a new release

Upgrade one release at a time: each release is tested from the one before it ([ADR-0017](../adr/0017-upgrades-between-releases.md), D1). To skip releases, follow this guide once for each.

## Before

1. Read the release's [CHANGELOG](../../CHANGELOG.md): its **Migration** notes say what changes in your configuration (an input to set, a stack removed) and what an apply may meet once.
2. Pin the new release in your deployment repository, and keep a copy of every state.
3. Update your inputs as the migration notes say: a plan with a missing required input fails before changing anything.

## The stacks, in the order of deployment

Plan each stack, read what it replaces and destroys, then apply it; the next one waits until the plan after apply is empty. The order is that of the deployment ([getting started](../getting-started/README.md)):

1. `shared/planes`;
2. the shared services (your receivers and internal services, `shared/egress`), then `shared/entry-point`;
3. the tenants, each with its own state;
4. `shared/planes` again on hub planes, then the publication of the domains ([publish a domain](publish-a-domain.md)).

```bash
s=stacks/shared/planes   # then each stack in turn
tofu -chdir=$s init -upgrade
tofu -chdir=$s plan -out=upgrade.plan
tofu -chdir=$s show -json upgrade.plan | jq -r '.resource_changes[] | select(.change.actions | index("delete")) | "\(.change.actions | join("/")) \(.address)"'
tofu -chdir=$s apply upgrade.plan && tofu -chdir=$s plan -detailed-exitcode
```

The services keep answering during the applies: the release campaign measures it ([test results](../concepts/test-results.md)). An apply that fails as a migration note says (for example a share created before the old one is destroyed) is applied again.

## The Kubernetes clusters

The stack of a cluster renders its manifests and scripts; the cluster takes them through its API. After the apply of each Kubernetes stack, update the cluster from an administration source ([update a cluster](kubernetes-lifecycle.md#update-a-cluster-after-an-apply)):

```bash
scripts/cluster-files.sh stacks/tenants/kubernetes ~/published
KUBECONFIG=published.kubeconfig ~/published/update-cluster.sh
```

When the release changes the versions of Cluster API and its providers, `update-cluster.sh` upgrades them. A bootstrap instance kept since an earlier release still has that release's scripts: copy the current ones to its `/opt/platform` before using it to delete a cluster ([delete a cluster](kubernetes-lifecycle.md#delete-a-cluster)).

## Check

- Every plan is empty.
- [Check the isolation](check-isolation.md): the new release may add rows.
- HTTPS answers on each published domain.
