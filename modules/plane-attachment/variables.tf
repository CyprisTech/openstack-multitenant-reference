variable "planes" {
  description = "Planes the stack joins, keyed by name (svc_public, monitoring, intranet)."
  type        = list(string)
}

variable "attachment" {
  description = "The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes), keyed by plane: one descriptor per plane, whatever provides it."
  type = map(object({
    mode         = string
    nat          = bool
    cidr         = string
    network_id   = string
    network_name = string
    subnet_id    = string
    routes       = optional(list(object({ destination = string, next_hop = string })), [])
  }))

  validation {
    condition     = alltrue([for p in values(var.attachment) : contains(["gateway", "interface"], p.mode)])
    error_message = "A plane mode is \"gateway\" or \"interface\"."
  }
}

variable "internal_subnet" {
  description = "Key of the subnet the plane routers are attached to, in the stack's network."
  type        = string
  default     = "main"
}

variable "default_gateway" {
  description = "Plane whose router is the default gateway of the stack's network (a tenant with no other way out), or null. Its range needs no route pushed by DHCP."
  type        = string
  default     = null
}

variable "instances" {
  description = "Instances whose ports are exposed on the planes (see exposure)."
  type        = list(string)
  default     = []
}

variable "exposure" {
  description = <<-EOT
    How the instances are reached on the planes. In gateway mode through floating IPs of the
    plane, in interface mode at their own address (nothing to create).
    - primary: plane of the port's primary floating IP (published backends), or null.
    - extra: planes of additional floating IPs (monitoring targets).
    - dns: A record per instance, named after it, in zone (key of the stack's DNS zones),
      for the address on plane: the floating IP in gateway mode, the fixed IP in interface mode.
  EOT
  type = object({
    primary = optional(string)
    extra   = optional(list(string), [])
    dns     = optional(object({ plane = string, zone = string }))
  })
  default = {}
}
