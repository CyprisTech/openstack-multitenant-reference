variable "cloud" {
  description = "Entry of clouds.yaml used by this stack."
  type        = string
}

variable "site" {
  description = "Short site name; must match the site of the entry point (stack shared/entry-point)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,15}$", var.site))
    error_message = "site must be 1 to 16 lowercase letters, digits or dashes."
  }
}

variable "az" {
  description = "Availability zone of the instances."
  type        = string
}

variable "image" {
  description = "Image name of the instance (an Ubuntu LTS cloud image)."
  type        = string
}

variable "flavor" {
  description = "Flavor name of the instance."
  type        = string
}

variable "boot_volume_size" {
  description = "Size in GiB of a root volume created from the image; null boots from the flavor's local disk."
  type        = number
  default     = null
}

variable "isolated_cidr" {
  description = "Range of the isolated network. With operator planes it may overlap the ranges of other tenants; on an interface plane it must not (shared/planes checks it)."
  type        = string
  default     = "10.22.0.0/24"
}

variable "plane_attachment" {
  description = <<-EOT
    The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),
    keyed by plane: how its router joins each plane and how its instances are seen there,
    whatever provides the plane (the operator, or a hub project).
  EOT
  type = map(object({
    mode         = string
    nat          = bool
    cidr         = string
    network_id   = string
    network_name = string
    subnet_id    = string
    routes       = optional(list(object({ destination = string, next_hop = string })), [])
  }))
}

variable "dns_nameservers" {
  description = "DNS resolvers of the tenant network, reachable through its routes."
  type        = list(string)
  default     = []
}

variable "admin" {
  description = "Administration access: users (login => SSH public keys, sudo granted) and SSH source ranges. No access by default."
  type = object({
    users     = optional(map(list(string)), {})
    ssh_cidrs = optional(list(string), [])
  })
  default = {}
}

variable "bastion" {
  description = <<-EOT
    Optional administration bastion. It lives in its own small network whose router joins
    external_network (an administration network such as an intranet) and carries a floating
    IP on it. A second port on the isolated network gives it access to the instance; the isolated
    network itself gets no route to the administration network.
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
    The users of var.admin are created on the bastion and on the isolated instance.
  EOT
  type = object({
    external_network = object({ network = string, subnet = string })
    cidr             = optional(string)
    flavor           = optional(string)
    ssh_cidrs        = list(string)
  })
  default = null
}

variable "network_mtu" {
  description = <<-EOT
    MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant
    networks, nor the MTU of the planes they join (planes contract): a larger value creates a
    path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator
    enables it. null keeps the cloud default.
  EOT
  type        = number
  default     = null
}

variable "monitoring" {
  description = <<-EOT
    Monitoring as a push integration point (ADR-0007): the workload pushes its metrics to the
    receiver through the monitoring plane, its only way out. Nothing connects into the tenant.
    - receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output
      receiver_url of the receiver); null pushes nothing.
  EOT
  type = object({
    receiver = optional(string)
  })
  default = {}
}
