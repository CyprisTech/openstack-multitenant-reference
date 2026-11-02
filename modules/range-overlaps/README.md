# Module `range-overlaps`

Finds overlapping IPv4 ranges — OpenTofu and Terraform have no built-in function for it. Each range has scopes: two ranges are compared only when they share one, or when one of them has the scope `*`. It creates nothing; `stacks/shared/planes` uses it to check that the planes overlap nothing and that the attachments of an interface plane do not overlap each other.

```hcl
module "overlaps" {
  source = "../../../modules/range-overlaps"
  ranges = {
    "plane svc_public" = { cidr = "172.31.0.0/24", scopes = ["*"] }
    "attachment web"   = { cidr = "10.21.0.0/24", scopes = ["svc_public"] }
  }
}
# module.overlaps.overlaps: [] or ["attachment a (10.21.0.0/24) and attachment b (10.21.0.0/22)"]
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
| ranges | IPv4 ranges to check, keyed by a name shown in the result. Two ranges are compared when they<br/>share a scope, or when one of them has the scope "*" (compared with every range). | <pre>map(object({<br/>    cidr   = string<br/>    scopes = list(string)<br/>  }))</pre> | n/a | yes |

### Outputs

| Name | Description |
| ---- | ----------- |
| overlaps | Pairs of overlapping ranges that share a scope, as "<name> (<cidr>) and <name> (<cidr>)"; empty when none. |
<!-- END_TF_DOCS -->
