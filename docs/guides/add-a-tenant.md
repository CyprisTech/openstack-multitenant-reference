# Add a tenant

A tenant is a project with its own credentials, joined to the shared planes it needs through its own routers ([How a tenant joins a plane](../concepts/plane-attachment.md)). The steps are the same for every tenant type and every cloud; step 6 only applies to planes built in a hub project (interface mode).

## 1. Project and credentials

Create the project (provider's console or API, or [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-tenant) on a private cloud), with resources in the same region as the other projects, and an application credential scoped to it, with the roles `member` and `load-balancer_member`. Add it to `clouds.yaml`. A Kubernetes tenant needs a second credential for the cluster itself ([Kubernetes tenant](../../stacks/tenants/kubernetes/README.md)).

## 2. Type and address range

Choose the tenant type: [`vm`](../../stacks/tenants/vm/README.md) (instances behind one service address, published through the entry point or with their own address), [`isolated`](../../stacks/tenants/isolated/README.md) (no public exposure) or [`kubernetes`](../../stacks/tenants/kubernetes/README.md) (a cluster with its ingress, published through the entry point or with its own address).

Choose its address range outside the planes' ranges. On hub planes (interface mode) it must also differ from every other attachment of the plane — and fall inside the plane's `tenant_ranges` aggregates, so that no shared service needs a new route. On operator planes (gateway mode), tenants may share ranges.

## 3. Declare the attachment

In `shared/planes`, add the tenant to `attachments` with its project ID, its range and its role on each plane it joins — `tenant`, unless it provides a service to the other attachments of that plane:

```hcl
attachments = {
  # ...
  shop = { project_id = "<project id>", cidr = "10.21.4.0/24", planes = { publication = "tenant", observability = "tenant" } }
}
```

Apply `shared/planes`: on hub planes, the plane networks are shared with the new project; on operator planes, nothing is created. Its entry of the `attachments` output (`tofu output -json attachments | jq .shop.planes`) is the tenant's `plane_attachment`.

## 4. Configure the stack

Each tenant has its own working directory or state key. Set:

| Input | Value |
|---|---|
| `cloud` | the tenant's `clouds.yaml` entry |
| `site` | the same as the other stacks |
| the tenant range (`web_cidr`, `isolated_cidr`, `cluster_cidr`) | step 2 |
| `plane_attachment` | the tenant's entry of the `attachments` output of `shared/planes` (step 3) |
| `edge_sources` (`vm`, `kubernetes`) | output `publication_sources` of the entry point |
| `monitoring.receiver` | the URL of your metrics receiver (output `receiver_url` of the test receiver) |

No stack reads an object of another project: what the tenant needs from the shared services comes from their outputs.

## 5. Apply

`tofu init && tofu apply`; the next `tofu plan` must be empty.

## 6. Hub planes: route to the tenant

Apply `shared/planes` again. It discovers the address Neutron gave the tenant's router on each plane and adds one route on the plane's transit router. Until then the shared services cannot reach the tenant. The tenant's own routes to the shared services were known in step 3: nothing to do on its side.

## 7. Publish and check

1. If the tenant serves domains, [publish them](publish-a-domain.md): the entry point routes them to the tenant's `published_domains` output.
2. If it provides an internal service, give the consumers' addresses to the service (for example `allowed_sources` from the Kubernetes tenant's `internal_sources`).
3. [Check the isolation](check-isolation.md): the new tenant must reach only what its type allows.

## Remove a tenant

The reverse order: withdraw its domains from the entry point, destroy its stack, then apply `shared/planes` (on hub planes, its route goes away), remove its entry and apply again. Neutron refuses to remove the RBAC policy while a port of the project is still on the plane.
