variable "name" {
  description = "Name of the bastion instance; its network, router and security group are named after it."
  type        = string
}

variable "bastion" {
  description = <<-EOT
    The bastion, or null for none (ADR-0005, D5). Where it lives: var.placement.
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
  EOT
  type = object({
    external_network = object({ network = string, subnet = optional(string) })
    cidr             = optional(string)
    flavor           = optional(string)
    ssh_cidrs        = list(string)
  })
}

variable "placement" {
  description = <<-EOT
    Where the bastion lives (ADR-0014, D2).
    - "own-network" (default): the bastion lives in its own small network whose
      router joins external_network (an administration network such as an intranet) and
      carries a floating IP on it; a second port on the stack's network gives it access to the
      stack's instances. The stack's network gets no path to the administration network.
    - "stack-network": one port on the stack's network, its floating IP on the
      stack's egress router. Only when external_network is the stack's egress network (the
      Internet on a public cloud): the separation would add nothing, and the bastion's replies
      follow the default route to that same router. Saves a network and a router.
  EOT
  type        = string
  default     = "own-network"

  validation {
    condition     = contains(["own-network", "stack-network"], var.placement)
    error_message = "placement is \"own-network\" or \"stack-network\"."
  }

  validation {
    condition = var.bastion == null || var.placement == "own-network" || (
      var.egress != null && try(var.bastion.external_network.network == var.egress.network, false)
    )
    error_message = "placement \"stack-network\" needs a stack with an egress network, and bastion.external_network must be that network."
  }
}

variable "egress" {
  description = "The stack's egress: key of its network in tenant.existing.networks (the floating IP pool) and that network's name; null for a stack with no egress."
  type = object({
    pool    = string
    network = string
  })
  default = null
}

variable "admin_network" {
  description = "Name of the bastion's own network (and key in tenant.networks)."
  type        = string
}

variable "default_cidr" {
  description = "Range of the bastion's network when bastion.cidr is not set."
  type        = string
}

variable "network" {
  description = "Key of the stack's network (subnet main) where the bastion gets its second port."
  type        = string
}

variable "port" {
  description = "Key of the bastion's second port, on the stack's network."
  type        = string
  default     = "main"
}

variable "users" {
  description = "Administrators created on the bastion: login => SSH public keys (sudo granted)."
  type        = map(list(string))
  default     = {}
}

variable "instance" {
  description = "Placement and image of the bastion, as for the stack's instances."
  type = object({
    az     = string
    image  = string
    flavor = string
    boot   = any
  })
}

variable "mtu" {
  description = "MTU of the bastion's network."
  type        = number
  default     = null
}

variable "dns_nameservers" {
  description = "Resolvers of the bastion's network."
  type        = list(string)
  default     = []
}
