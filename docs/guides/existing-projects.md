# Bring existing projects into the reference

Most organisations start with projects that already run: networks, routers, security groups and instances created by hand, by scripts or by another tool, outside any state of this repository. This guide says what to do with them, project by project, and how to do it when there are thousands of objects.

## Why move

What a project gains by becoming a tenant of the reference:

- **Isolation you can prove.** The [isolation test](check-isolation.md) checks every allowed and denied flow after each change, instead of trusting rules nobody reads.
- **One way in.** Domains are published through the shared entry point (SNI, TLS passthrough): no floating IP per application, no public port opened project by project.
- **Monitoring without a way in.** Metrics are pushed to the receiver; nothing on the observability plane connects into the project.
- **Changes that are reviewed and rebuilt.** Every object is in code: a change is a merge request, a lost project is [rebuilt](rebuild.md) from the repository.
- **The same model on every cloud.** The same stacks run on any OpenStack cloud with a member role.

Nothing forces a single migration: projects come in one at a time, and the others keep running as they are.

## Three ways, chosen per project

| | Connect | Take over | Rebuild beside |
|---|---|---|---|
| What happens | The project keeps its objects; it joins the planes as an attachment | Its network objects move into a tenant stack; its instances stay outside or are replaced | A new tenant is built; the workload moves to it; the old project is retired |
| Isolation | The planes and their admissions only: the project's own rules stay yours | Everything the stack describes | Everything |
| Effort | Low | Medium: one model and one import list per project | The workload's own migration |
| Instances | Untouched | Left out of the module, or replaced (below) | Recreated from code |
| Choose it for | A project that must not move now | Long-lived networks with workloads that cannot be recreated | Workloads that can be redeployed (images, Kubernetes, configuration management) |

**Connect.** Declare the project in `shared/planes` (`attachments`: its project, range and role on each plane), then join the planes from the project as the [planes contract](../reference/planes-contract.md) says: a router gateway on each operator plane, or an interface and routes on each hub plane, and the admissions of the shared services. Any tool can do it; the [`plane-attachment`](../../modules/plane-attachment/README.md) module writes it for a stack of this repository. The range rules of [add a tenant](add-a-tenant.md) apply: on hub planes, a range unique among the attachments.

**Take over.** Write the project as a tenant stack, starting from [`vm`](../../stacks/tenants/vm/README.md) or [`isolated`](../../stacks/tenants/isolated/README.md), with the same names, ranges and rules as the objects, then import them with `import` blocks as [terraform-openstack-tenant's takeover guide](https://github.com/CyprisTech/terraform-openstack-tenant/blob/main/docs/takeover.md) describes. The plan must import every object and create or destroy nothing. Instances are the exception: the provider does not record the port of an imported instance, so taking one over replaces it. Keep their data on volumes and let them be replaced, or leave them out of the stack.

**Rebuild beside.** [Add a tenant](add-a-tenant.md), deploy the workload into it, switch its domains with a [publication](publish-a-domain.md), then delete the old project.

What the cloud operator owns (projects, quotas, users, roles, external networks) is level 1: adopt it as it is, or take it over with [cloud-baseline](https://github.com/CyprisTech/terraform-openstack-cloud-baseline) on a private cloud.

## At scale

Thousands of objects are not written by hand, one `import` block each:

1. **One stack per project.** States stay small, a mistake stays in one project, and projects move one after the other.
2. **Generate the inventory from the API.** List the objects of a project (`openstack ... list -f json`) and turn them into two things: the model of the stack (keyed by name) and the list of IDs to import, keyed the same way.
3. **One `import` block per kind of object**, with `for_each` over the generated list (OpenTofu and Terraform 1.7 and later):

   ```hcl
   import {
     for_each = var.web_rules # generated: "<protocol>-<port>" => { id, protocol, port, remote_ip_prefix }
     to       = module.tenant.module.security_group["web"].openstack_networking_secgroup_rule_v2.this[each.key]
     id       = each.value.id
   }
   ```

   terraform-openstack-tenant's stage [`06-takeover`](https://github.com/CyprisTech/terraform-openstack-tenant/tree/main/tests/integration/06-takeover) does exactly this, from the API, on a real cloud.
4. **Read the plan before applying**: every object imported, nothing created or destroyed. A creation or a replacement means the model does not match the object: correct the generated model, not the object.
5. **Then run the isolation test** for the project. The test of this repository checks the reference scenario; for a project of your own, add its rows to the [isolation matrix](../reference/isolation-matrix.md) the same way.

## What is not covered

- Projects administered by several organisations, and a single application in a single project ([scope](../../README.md#scope)).
- An automatic converter from a project to a stack: the inventory and the model are generated by your scripts. It may come if users ask for it.
