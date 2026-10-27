variable "cloud" {
  description = "Entry of clouds.yaml used by this configuration: the project that will own the image (the platform project)."
  type        = string
}

variable "site" {
  description = "Short site name, part of the resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,15}$", var.site))
    error_message = "site must be 1 to 16 lowercase letters, digits or dashes."
  }
}

variable "build_cidr" {
  description = "Range of the build network. A small range is enough: one build instance at a time."
  type        = string
  default     = "10.41.0.0/28"
}

variable "egress_network" {
  description = "External network that gives the build instance Internet access (default route)."
  type        = object({ network = string, subnet = string })
}

variable "admin_network" {
  description = "Administration network (layer 10 contract): Packer connects to a floating IP of this network."
  type        = object({ network = string, subnet = string })
}

variable "ssh_cidrs" {
  description = <<-EOT
    Administration sources allowed to reach the build instance on port 22: the address of the
    machine that runs Packer, as seen on the administration network. They are also advertised
    as routes through the administration router, so specific addresses are expected, not
    the range of the network (ADR-0002, D6).
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ssh_cidrs) > 0 && alltrue([for c in var.ssh_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "ssh_cidrs needs at least one CIDR, and no default route (/0)."
  }
}

variable "dns_nameservers" {
  description = "DNS resolvers of the build network, reachable through the egress network."
  type        = list(string)
  default     = []
}

variable "network_mtu" {
  description = <<-EOT
    MTU of the build network. It must not exceed the MTU the cloud can carry for tenant networks,
    nor the MTU of the networks it joins (layer 10 contract). null keeps the cloud default.
  EOT
  type        = number
  default     = null
}
