variable "cloud" {
  description = "Entry of clouds.yaml used by this stack."
  type        = string
}

variable "site" {
  description = "Short site name: the name of the region in this deployment, used in resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,15}$", var.site))
    error_message = "site must be 1 to 16 lowercase letters, digits or dashes."
  }
}

variable "zones" {
  description = "Availability zones of the instances, at least one. The instances of a role are spread over them in order (the first instance in the first zone); changing the order moves instances. One zone places everything in it."
  type        = list(string)

  validation {
    condition     = length(var.zones) > 0 && length(distinct(var.zones)) == length(var.zones)
    error_message = "zones must list at least one zone, without duplicates."
  }
}

variable "volume_zones" {
  description = "Block storage zone of the root volumes (boot_volume_size), for each compute zone. A compute zone missing from the map gets the cloud's default storage zone."
  type        = map(string)
  default     = {}
}

variable "image" {
  description = "Image name of the proxy instances (an Ubuntu LTS cloud image)."
  type        = string
}

variable "flavor" {
  description = "Flavor name of the proxy instances."
  type        = string
}

variable "boot_volume_size" {
  description = "Size in GiB of a root volume created from the image; null boots from the flavor's local disk."
  type        = number
  default     = null
}

variable "instance_count" {
  description = "Number of proxy instances behind the load balancer: two or more keeps the egress up while one is replaced or its host fails."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1."
  }
}

variable "egress_cidr" {
  description = "Range of the stack's network: the load balancer, its amphorae and the proxy instances live in it. On a hub plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.39.0.0/27"
}

variable "dns_nameservers" {
  description = "DNS resolvers of the stack's network; empty (the default), those of Neutron's DHCP (ADR-0016, D3). The proxies resolve the names the tenants ask for with them: they must resolve public names."
  type        = list(string)
  default     = []
}

variable "egress_network" {
  description = "External network of the stack's egress router: the way out to the Internet of the proxies. subnet: optional, the subnet of that network to look up by name."
  type = object({
    network = string
    subnet  = optional(string)
  })
}

variable "plane_attachment" {
  description = <<-EOT
    The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),
    keyed by plane: how its router joins each plane and how its instances are seen there,
    whatever provides the plane (the operator, or a hub project). The proxies are a
    shared service of the internal services plane (role shared).
  EOT
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
}

variable "tenants" {
  description = <<-EOT
    The tenants that go out through this egress (egress = "shared", ADR-0016 D1), keyed by name
    (lowercase letters, digits, dashes):
    - sources: the addresses the tenant arrives from on the internal services plane: its
      internal_sources output (its router's address on a plane with NAT, its range otherwise).
    - domains: the names it may reach, in Squid's dstdomain form: "example.org" for that name
      only, ".example.org" for it and its subdomains. Everything else is refused.
    Empty: the proxies refuse every request.
  EOT
  type = map(object({
    sources = list(string)
    domains = list(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.tenants) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "The keys of tenants are lowercase letters, digits and dashes."
  }

  validation {
    condition     = alltrue([for t in values(var.tenants) : length(t.sources) > 0 && length(t.domains) > 0])
    error_message = "Each tenant declares at least one source and one domain."
  }
}

variable "squid_port" {
  description = "Port of the proxy, on the load balancer and the instances."
  type        = number
  default     = 3128
}

variable "octavia_flavor_id" {
  description = "Octavia flavor; an active/standby flavor is recommended. null uses the cloud default."
  type        = string
  default     = null
}

variable "server_group_policy" {
  description = "Placement of the proxy instances: \"anti-affinity\" (two hosts required) or \"soft-anti-affinity\"."
  type        = string
  default     = "anti-affinity"

  validation {
    condition     = contains(["anti-affinity", "soft-anti-affinity"], var.server_group_policy)
    error_message = "server_group_policy must be anti-affinity or soft-anti-affinity."
  }
}

variable "admin" {
  description = <<-EOT
    Administration access to the proxy instances. users: login => SSH public keys (sudo granted).
    ssh_cidrs: sources allowed on port 22. Empty by default: no SSH access.
  EOT
  type = object({
    users     = optional(map(list(string)), {})
    ssh_cidrs = optional(list(string), [])
  })
  default = {}
}

variable "bastion" {
  description = <<-EOT
    Optional administration bastion. By default it lives in its own small network whose router joins
    external_network (an administration network such as an intranet) and carries a floating
    IP on it. A second port on the stack's network gives it access to the proxy instances; that
    network itself gets no route to the administration network.
    var.bastion_placement may put it on the stack's network instead (ADR-0014, D2).
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
    The users of var.admin are created on the bastion and on the proxy instances.
  EOT
  type = object({
    external_network = object({
      network = string
      subnet  = optional(string)
    })
    cidr      = optional(string)
    flavor    = optional(string)
    ssh_cidrs = list(string)
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
    Monitoring as a push integration point (ADR-0007): each proxy instance runs its exporters
    and a Prometheus agent that reads them, and pushes to the receiver
    through the observability plane. Nothing connects into the instances for their metrics.
    - receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output
      receiver_url of the receiver); null runs no agent.
  EOT
  type = object({
    receiver = optional(string)
  })
  default = {}
}

variable "bastion_placement" {
  description = <<-EOT
    Where the bastion lives (ADR-0014, D2): "own-network" (default), its own small network whose
    router joins bastion.external_network; or "stack-network", one port on the stack's network
    and its floating IP on the egress router, when bastion.external_network is the egress_network.
    A choice of the profile: private-cloud keeps "own-network", public-cloud takes "stack-network".
  EOT
  type        = string
  default     = "own-network"

  validation {
    condition     = contains(["own-network", "stack-network"], var.bastion_placement)
    error_message = "bastion_placement is \"own-network\" or \"stack-network\"."
  }

  validation {
    condition     = var.bastion_placement != "stack-network" || var.bastion == null || try(var.bastion.external_network.network == var.egress_network.network, false)
    error_message = "bastion_placement \"stack-network\" needs bastion.external_network to be the public_network (ADR-0014, D2)."
  }
}
