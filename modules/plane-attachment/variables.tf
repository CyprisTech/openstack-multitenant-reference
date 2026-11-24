variable "planes" {
  description = "Planes the stack joins, keyed by name (publication, observability, internal)."
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
    routes = optional(list(object({
      destination = string
      next_hop    = string
    })), [])
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

variable "default_router" {
  description = "Key of the router that gets the default route (0.0.0.0/0) of the transit router: the stack's egress router, a plane's router (the plane's name, for a tenant whose only way out is that plane), or null for no default route (unknown destinations are dropped)."
  type        = string
  default     = null
}

variable "routes" {
  description = "Other destinations of the stack, reached through its own routers: router key => destinations (for example the administration network through the router on it). They become routes of the transit router too."
  type        = map(list(string))
  default     = {}
}

variable "instances" {
  description = "Instances whose ports are exposed on the planes (see exposure)."
  type        = list(string)
  default     = []
}

variable "exposure" {
  description = <<-EOT
    How the instances are reached on the planes: through a floating IP of the plane when it
    translates addresses, at their own address otherwise (nothing to create). At most one
    floating IP per address (ADR-0006, D4).
    - primary: plane on which each instance is a service address, or null.
  EOT
  type = object({
    primary = optional(string)
  })
  default = {}
}
