# Module `admission`

Ingress rules written as flows — "these sources may reach these ports" — instead of one rule per port and source. It creates nothing: the output is the `rules` map of a security group in the tenant model of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant), keyed `<flow>-<port>-<source>`.

```hcl
module "admission" {
  source = "../../../modules/admission"

  allow = {
    https-from-edge = { ports = [443], sources = local.edge_sources }
    metrics         = { ports = [9100], sources = var.monitoring.collector_cidrs }
    ssh             = { ports = [22], sources = var.admin.ssh_cidrs }
  }
}
```

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allow | Who may reach the instances, keyed by a name for the flow (https-from-edge, metrics, ssh):<br/>TCP ports and the source ranges admitted on each of them. | <pre>map(object({<br/>    ports   = list(number)<br/>    sources = list(string)<br/>  }))</pre> | n/a | yes |

### Outputs

| Name | Description |
| ---- | ----------- |
| rules | Ingress rules, for tenant.security\_groups.<group>.rules. |
<!-- END_TF_DOCS -->
