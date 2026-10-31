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
  description = "Image name of the web instances (an Ubuntu LTS cloud image)."
  type        = string
}

variable "flavor" {
  description = "Flavor name of the web instances."
  type        = string
}

variable "boot_volume_size" {
  description = "Size in GiB of a root volume created from the image; null boots from the flavor's local disk."
  type        = number
  default     = null
}

variable "web_cidr" {
  description = "Range of the web network. Tenants may reuse the same range: they never route to each other."
  type        = string
  default     = "10.21.0.0/24"
}

variable "dns_nameservers" {
  description = "DNS resolvers of the web network, reachable through its routes."
  type        = list(string)
  default     = []
}

variable "egress_network" {
  description = "External network giving the default route (package installation). The instances get no public address on it."
  type = object({
    network = string
    subnet  = string
  })
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

variable "edge_sources" {
  description = <<-EOT
    Ranges the entry point connects from on svc_public, in CIDR notation: output
    svc_public_sources of stack shared/entry-point. Only they may reach the published port and
    send a PROXY protocol header. null reads the entry point's router by name, which works only
    when the entry point is in the same project.
  EOT
  type        = list(string)
  default     = null
}

variable "domains" {
  description = "Domains served by the web instances and published through the entry point."
  type        = list(string)
  default     = ["site-a.example.org", "site-b.example.org"]
}

variable "server_group_policy" {
  description = "Placement of the two web instances: \"anti-affinity\" or \"soft-anti-affinity\"."
  type        = string
  default     = "anti-affinity"

  validation {
    condition     = contains(["anti-affinity", "soft-anti-affinity"], var.server_group_policy)
    error_message = "server_group_policy must be anti-affinity or soft-anti-affinity."
  }
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
    IP on it. A second port on the web network gives it access to the web instances; the web
    network itself gets no route to the administration network.
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
    The users of var.admin are created on the bastion and on the web instances.
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
    Exposure of the instances to the monitoring collector (ADR-0001, D2): every instance gets a
    floating IP of the monitoring plane.
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
