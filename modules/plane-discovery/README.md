# Module `plane-discovery`

Finds the address Neutron gave each attached router on a shared private plane ([How a tenant joins a plane](../../docs/concepts/plane-attachment.md), mode 2). An attached project cannot choose its address on a network it does not own, but the plane's owner — the hub project — sees every port on it: with the hub's credentials, this module lists the router interfaces of each attached project on its plane. It creates nothing; `stacks/shared/planes` routes the transit router to the addresses found.

The plane is read by its subnet's range — unique in the hub project, and never renamed — so that the first apply, before the plane exists, still plans: nothing is found then, and the next apply finds the routers attached since. The discovery relies on Neutron's default policy that lets a network's owner read the ports on it.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| openstack | ~> 3.2 |

### Providers

| Name | Version |
| ---- | ------- |
| openstack | ~> 3.2 |

### Resources

| Name | Type |
| ---- | ---- |
| [openstack_networking_port_ids_v2.attachment](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_port_ids_v2) | data source |
| [openstack_networking_port_v2.attachment](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_port_v2) | data source |
| [openstack_networking_subnet_ids_v2.plane](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_subnet_ids_v2) | data source |
| [openstack_networking_subnet_v2.plane](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_subnet_v2) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| attachments | One entry per attachment and plane, keyed as you like: the plane and the attached project. | `map(object({ plane = string, project_id = string }))` | n/a | yes |
| hub\_project\_id | Project owning the planes; its credentials see every port on them. | `string` | n/a | yes |
| planes | Hub planes, keyed by plane: the range of their subnet in the hub project (unique there). | `map(string)` | n/a | yes |

### Outputs

| Name | Description |
| ---- | ----------- |
| addresses | IPv4 address of each attached router on its plane, keyed like attachments; attachments not joined yet are absent. |
| interface\_counts | Number of router interfaces each attached project has on its plane; one is expected. |
<!-- END_TF_DOCS -->
