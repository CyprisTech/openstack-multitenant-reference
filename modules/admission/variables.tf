variable "allow" {
  description = <<-EOT
    Who may reach the instances, keyed by a name for the flow (https, ssh):
    ports, the source ranges admitted on each of them, and the protocol (tcp by default).
  EOT
  type = map(object({
    ports    = list(number)
    sources  = list(string)
    protocol = optional(string, "tcp")
  }))
  validation {
    condition     = alltrue([for a in values(var.allow) : contains(["tcp", "udp"], a.protocol)])
    error_message = "protocol must be tcp or udp."
  }
}
