# Intranet demonstration service

An internal service, a **shared service of the intranet plane**, for the [isolation test](../../isolation/README.md) ([ADR-0002](../../../docs/adr/0002-platform-kubernetes.md), D7): the Kubernetes tenant must reach it, the other tenants must not. It answers on port 8080 and admits on that port only `allowed_sources`: the `intranet_sources` output of the Kubernetes tenant.

- On an operator plane (gateway mode), it has a floating IP of the intranet, which also carries SSH for the administration sources.
- On an interface plane (`shared/planes`, role `shared` on `intranet`), it is reached at its own address, through the transit router.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
allowed_sources = ["198.51.100.7/32"] # intranet_sources output of the Kubernetes tenant
ssh_cidrs       = ["192.0.2.10/32"]
ssh_keys        = ["ssh-ed25519 AAAA..."]
VARS
tofu -chdir=../../../stacks/shared/planes output -json attachments | jq '{plane_attachment: ."intranet-service".planes}' > planes.auto.tfvars.json
tofu init && tofu apply
```

Like any shared service, it runs in its own project, not in the hub project (which holds the network only).

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| openstack | ~> 3.2 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| admission | ../../../modules/admission | n/a |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.3 |
| planes | ../../../modules/plane-attachment | n/a |
| service | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | 84c898b5d5036296a7cd3496a54e0721ccbc4936 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allowed\_sources | Sources admitted on port 8080: output intranet\_sources of the Kubernetes tenant. | `list(string)` | n/a | yes |
| az | n/a | `string` | n/a | yes |
| cloud | n/a | `string` | n/a | yes |
| flavor | n/a | `string` | n/a | yes |
| image | n/a | `string` | n/a | yes |
| plane\_attachment | The service's entry of the attachments output of stack shared/planes (role shared on intranet). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| site | n/a | `string` | n/a | yes |
| ssh\_cidrs | n/a | `list(string)` | n/a | yes |
| ssh\_keys | n/a | `list(string)` | n/a | yes |
| boot\_volume\_size | n/a | `number` | `null` | no |
| cidr | Range of the service's network; on an interface plane, the attachment's cidr in shared/planes. | `string` | `"10.35.0.0/28"` | no |
| network\_mtu | n/a | `number` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| address | Address of the service on the intranet (port 8080): its floating IP on an operator plane (which also carries SSH), its own address on an interface plane. |
| service\_sources | Sources admitted on port 8080. |
<!-- END_TF_DOCS -->
