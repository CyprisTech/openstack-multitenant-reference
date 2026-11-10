# Open a service after qualification

How a tested release reaches its users without being rebuilt, and how opening it to them stays a reviewed change. The landing zone owns the last step only: the domain on the entry point, or the consumers of an internal service. How the application is built and deployed (a CI pipeline, Flux, Argo CD) belongs to your platform ([integration points](../reference/integration-points.md#automation-a-gitops-pipeline)).

## The principle

1. **What was qualified is what goes to production.** Promote the artifact, not its source: the container image by its digest, the chart by its version, the virtual machine image by its ID. Rebuilding for production would deploy something that was never tested.
2. **Opening is a separate change, in the repository of your stacks.** Deploying the release does not expose it; adding its domain or its consumers does. That change goes through review, like any change of the infrastructure.
3. **Going back is the same path.** Revert the commit and apply: the domain leaves the entry point, the consumers lose access. The release itself stays deployed.

## A public service

1. **Deploy the release** in the production tenant, with the promoted digest. Nothing points to it yet.
2. **Qualify it in place, before any DNS record.** Add its domain to the tenant (`domains` of a `vm` tenant, `cluster.domains` of a `kubernetes` tenant), apply the tenant, then publish:

   ```bash
   OS_CLOUD=<entry of the entry point's project> scripts/publish-domains.sh
   curl --resolve <domain>:443:<entry point address> https://<domain>/
   ```

   The route exists but no record points to it yet. It is reachable by anyone who knows the address and the name, so test with test data, behind the application's authentication.
3. **Open it**: the A record of the domain on the entry point's address ([publish a domain](publish-a-domain.md)). This is the change users see.

## An internal service

On the [cluster for shared services](../../stacks/shared/kubernetes/README.md), a service is closed until its consumers are declared. Qualify it from the cluster or from a test consumer, then add the real consumers to `consumers` ([add a consumer](../../stacks/shared/kubernetes/README.md#add-a-consumer)) and write its name in the zone of the internal names.

## In a pipeline

Each step is non-interactive, so a pipeline can run it after review:

| Change, reviewed in a merge request | Job, after the merge |
|---|---|
| the digest of the release in the tenant's deployment | your deployment tool (CI job, Flux, Argo CD) |
| the domain in the tenant's inputs | `tofu apply` of the tenant, then `scripts/publish-domains.sh` |
| the DNS record, or the consumers | your DNS provider; `tofu apply` of the shared cluster and its manifests |

Show the plan in the merge request (`tofu plan` of the tenant and of the entry point): the reviewer sees exactly which routes appear. The pipeline's credentials are those of each project, kept in its secret store, never in the repository. `publish-domains.sh` refuses to withdraw every domain at once (`--allow-empty` forces it), which protects production from an empty output after a failed apply.
