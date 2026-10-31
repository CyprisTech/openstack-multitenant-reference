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
