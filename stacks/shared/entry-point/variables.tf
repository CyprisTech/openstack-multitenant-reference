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

variable "az" {
  description = "Availability zone of the instances."
  type        = string
}

variable "image" {
  description = "Image name of the edge instances (an Ubuntu LTS cloud image)."
  type        = string
}

variable "flavor" {
  description = "Flavor name of the edge instances."
  type        = string
}

variable "boot_volume_size" {
  description = "Size in GiB of a root volume created from the image; null boots from the flavor's local disk."
  type        = number
  default     = null
}

variable "edge_cidr" {
  description = "Range of the edge network. The load balancer, its amphorae and the Traefik instances live in it."
  type        = string
  default     = "10.20.0.0/24"
}

variable "dns_nameservers" {
  description = "DNS resolvers pushed by DHCP on the edge network. They must be reachable through the edge routes (public network or a plane), and resolve the backend names used in routes. Without them, the first boot cannot install Podman nor pull the Traefik image."
  type        = list(string)
  default     = []
}

variable "public_network" {
  description = "External network providing the public floating IP of the load balancer and the default route of the edge network."
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

variable "octavia_flavor_id" {
  description = "Octavia flavor; an active/standby flavor is recommended for the edge. null uses the cloud default."
  type        = string
  default     = null
}

variable "server_group_policy" {
  description = "Placement of the two Traefik instances: \"anti-affinity\" (two hosts required) or \"soft-anti-affinity\"."
  type        = string
  default     = "anti-affinity"

  validation {
    condition     = contains(["anti-affinity", "soft-anti-affinity"], var.server_group_policy)
    error_message = "server_group_policy must be anti-affinity or soft-anti-affinity."
  }
}

variable "traefik_image" {
  description = "Fully qualified, pinned Traefik image."
  type        = string
  default     = "docker.io/library/traefik:v3.7.16"

  validation {
    condition     = !endswith(var.traefik_image, ":latest") && length(split(":", var.traefik_image)) > 1
    error_message = "traefik_image must carry an explicit version tag."
  }
}

variable "domains" {
  description = <<-EOT
    Public domains routed by SNI, keyed by domain name (ADR-0006).
    - backends: "address:port" of the tenant's service address (its load balancer, or its only
      instance); several only for a tenant that exposes several addresses for one domain.
    - proxy_protocol: send PROXY protocol v2 to the backends; they must be configured to accept it.
    - max_connections: simultaneous connections allowed per client address.
    Delivered to the Traefik instances through their metadata, updated in place: a change takes
    effect in seconds, without replacing an instance. scripts/publish-domains.sh fills it from the
    published_domains outputs of the tenants.
  EOT
  type = map(object({
    backends        = list(string)
    proxy_protocol  = optional(bool, true)
    max_connections = optional(number, 100)
  }))
  default = {}

  validation {
    condition     = alltrue([for r in values(var.domains) : length(r.backends) > 0])
    error_message = "Each domain needs at least one backend."
  }

  # Nova metadata: 128 items per instance by default (quota metadata_items), 255 characters per
  # key and per value.
  validation {
    condition     = length(var.domains) <= 120
    error_message = "At most 120 domains per entry point (Nova metadata quota)."
  }

  validation {
    condition = alltrue([
      for d, r in var.domains : length("route-${d}") <= 255 && length(jsonencode({ b = r.backends, p = r.proxy_protocol, m = r.max_connections })) <= 255
    ])
    error_message = "A route does not fit in a metadata item (255 characters): fewer backends or a shorter domain."
  }
}

variable "admin" {
  description = <<-EOT
    Administration access to the Traefik instances. users: login => SSH public keys (sudo granted).
    ssh_cidrs: sources allowed on port 22. Empty by default: no SSH access.
  EOT
  type = object({
    users     = optional(map(list(string)), {})
    ssh_cidrs = optional(list(string), [])
  })
  default = {}
}

variable "public_dns" {
  description = "Optional A records on the public floating IP: an existing zone (name with its trailing dot) and relative names (\"\" for the apex)."
  type = object({
    zone  = string
    names = list(string)
    ttl   = optional(number, 300)
  })
  default = null
}

variable "bastion" {
  description = <<-EOT
    Optional administration bastion. It lives in its own small network whose router joins
    external_network (an administration network such as an intranet) and carries a floating
    IP on it. A second port on the edge network gives it access to the Traefik instances; the edge
    network itself gets no route to the administration network.
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
    The users of var.admin are created on the bastion and on the Traefik instances.
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
    Monitoring as a push integration point (ADR-0007): each Traefik instance runs its exporters
    and a Prometheus agent that reads them, with the Traefik metrics, and pushes to the receiver
    through the observability plane. Nothing connects into the instances for their metrics.
    - receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output
      receiver_url of the receiver); null runs no agent.
  EOT
  type = object({
    receiver = optional(string)
  })
  default = {}
}
