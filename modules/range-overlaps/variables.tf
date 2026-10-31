variable "ranges" {
  description = <<-EOT
    IPv4 ranges to check, keyed by a name shown in the result. Two ranges are compared when they
    share a scope, or when one of them has the scope "*" (compared with every range).
  EOT
  type = map(object({
    cidr   = string
    scopes = list(string)
  }))

  validation {
    condition     = alltrue([for r in values(var.ranges) : can(cidrhost(r.cidr, 0)) && !strcontains(r.cidr, ":")])
    error_message = "Each range needs an IPv4 cidr."
  }
}
