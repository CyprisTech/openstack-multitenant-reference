variable "cloud" {
  description = "Entry of clouds.yaml used by this stack."
  type        = string
}

variable "site" {
  description = "Short site name; must match the site of the public entry point (stack 20)."
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
  description = "DNS resolvers of the web network, reachable through its routes."
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
    cidr             = optional(string, "10.31.0.0/28")
    flavor           = optional(string)
    ssh_cidrs        = list(string)
  })
  default = null
}

variable "network_mtu" {
  description = <<-EOT
    MTU of the networks of this stack. It must not exceed the MTU the cloud can carry for tenant
    networks, nor the MTU of the planes they join (layer 10 contract): a larger value creates a
    path MTU black hole, since OVN routers do not send "fragmentation needed" unless the operator
    enables it. null keeps the cloud default.
  EOT
  type        = number
  default     = null
}

variable "monitoring" {
  description = <<-EOT
    Exposure of the instance to the monitoring collector (ADR-0001, D2): a floating IP of the
    monitoring plane in gateway mode, its own address in interface mode.
    - dns_zone: zone shared with the project (name with its trailing dot) where an A record per
      instance is written for the collector's DNS service discovery; null writes no record.
    - metrics_ports: ports opened to the collector (node exporter by default).
    - collector_cidrs: addresses of the collector as seen by the instances. null opens the
      metrics ports to the whole monitoring plane range, which includes the routers of every
      tenant joining that plane: set it to keep tenants from scraping each other.
  EOT
  type = object({
    dns_zone        = optional(string)
    metrics_ports   = optional(list(number), [9100])
    collector_cidrs = optional(list(string))
  })
  default = {}
}
