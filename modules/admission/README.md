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
