variable "allow" {
  description = <<-EOT
    Who may reach the instances, keyed by a name for the flow (https-from-edge, metrics, ssh):
    TCP ports and the source ranges admitted on each of them.
  EOT
  type = map(object({
    ports   = list(number)
    sources = list(string)
  }))
}
