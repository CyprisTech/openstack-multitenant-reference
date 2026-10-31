# Overlapping IPv4 ranges, which OpenTofu and Terraform cannot test with a built-in function: each
# range becomes [first address, size] as integers, and two ranges overlap when each one starts
# before the other ends. No resource.

locals {
  bounds = {
    for k, r in var.ranges : k => {
      first = sum([for i, octet in split(".", cidrhost(r.cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
      size  = pow(2, 32 - tonumber(split("/", r.cidr)[1]))
    }
  }
  names = sort(keys(var.ranges))

  overlaps = flatten([
    for i, a in local.names : [
      for j, b in local.names : "${a} (${var.ranges[a].cidr}) and ${b} (${var.ranges[b].cidr})"
      if i < j
      && local.bounds[a].first < local.bounds[b].first + local.bounds[b].size
      && local.bounds[b].first < local.bounds[a].first + local.bounds[a].size
      && (contains(var.ranges[a].scopes, "*") || contains(var.ranges[b].scopes, "*") || length(setintersection(var.ranges[a].scopes, var.ranges[b].scopes)) > 0)
    ]
  ])
}
