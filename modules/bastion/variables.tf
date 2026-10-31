variable "name" {
  description = "Name of the bastion instance; its network, router and security group are named after it."
  type        = string
}

variable "bastion" {
  description = <<-EOT
    The bastion, or null for none. It lives in its own small network whose router joins
    external_network (an administration network such as an intranet) and carries a floating IP
    on it; a second port on the stack's network gives it access to the stack's instances.
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
  EOT
  type = object({
    external_network = object({ network = string, subnet = string })
    cidr             = optional(string)
    flavor           = optional(string)
    ssh_cidrs        = list(string)
  })
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
