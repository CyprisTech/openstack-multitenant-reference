variable "cloud" {
  description = "Entry of clouds.yaml used by this stack."
  type        = string
}

variable "site" {
  description = "Short site name, used in resource names (ADR-0001, D9)."
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
    Public domains routed by SNI, keyed by domain name.
    - backends: "host:port" of the backends (addresses or names resolvable from the edge network).
    - proxy_protocol: send PROXY protocol v2 to the backends; they must be configured to accept it.
    - max_connections: simultaneous connections allowed per client address.
    A change takes effect when the instances are replaced, one at a time: scripts/publish-domains.sh
    does it from the published_domains outputs of the tenants (see README).
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
    Exposure of the instances to the monitoring collector. On a plane with NAT, every instance
    gets a floating IP of the monitoring plane; on an interface plane, it is reached at its own
    address.
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
