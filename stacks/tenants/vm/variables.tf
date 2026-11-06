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
  description = "Image name of the instances (an Ubuntu LTS cloud image)."
  type        = string
}

variable "flavor" {
  description = "Flavor name of the instances."
  type        = string
}

variable "boot_volume_size" {
  description = "Size in GiB of a root volume created from the image; null boots from the flavor's local disk."
  type        = number
  default     = null
}

variable "web_cidr" {
  description = "Range of the tenant network. On planes with NAT tenants may reuse the same range; on interface planes it must be unique (stack shared/planes checks it)."
  type        = string
  default     = "10.21.0.0/24"
}

variable "dns_nameservers" {
  description = "DNS resolvers of the tenant network, reachable through its routes."
  type        = list(string)
  default     = []
}

variable "egress_network" {
  description = "External network giving the default route (package installation). The instances get no public address on it; with exposure = \"public\", the service address is a floating IP of this network."
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

variable "instance_count" {
  description = "Number of instances. Above one, a load balancer is the service address (ADR-0006, D1); with one, the instance itself."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1."
  }
}

variable "exposure" {
  description = <<-EOT
    How the service address is published (ADR-0006, D2):
    - "entry-point": through the shared entry point (output published_domains), reachable from
      the entry point only;
    - "public": a floating IP of egress_network, reachable from anywhere; the shared entry point
      is not used.
  EOT
  type        = string
  default     = "entry-point"

  validation {
    condition     = contains(["entry-point", "public"], var.exposure)
    error_message = "exposure must be \"entry-point\" or \"public\"."
  }
}

variable "edge_sources" {
  description = <<-EOT
    Ranges the entry point connects from on svc_public, in CIDR notation: output
    svc_public_sources of stack shared/entry-point. Only they may reach the service address.
    Required with exposure = "entry-point".
  EOT
  type        = list(string)
  default     = []
}

variable "domains" {
  description = "Domains served by the instances and published through the entry point."
  type        = list(string)
  default     = ["site-a.example.org", "site-b.example.org"]
}

variable "server_group_policy" {
  description = "Placement of the instances: \"anti-affinity\" or \"soft-anti-affinity\"."
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
    IP on it. A second port on the web network gives it access to the instances; the web
    network itself gets no route to the administration network.
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
    The users of var.admin are created on the bastion and on the instances.
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
    Monitoring as a push integration point (ADR-0007): each instance runs its exporters and a
    Prometheus agent that pushes to the receiver through the monitoring plane. Nothing connects
    into the instances for their metrics.
    - receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output
      receiver_url of the receiver); null runs no agent.
  EOT
  type = object({
    receiver = optional(string)
  })
  default = {}
}

variable "certificates" {
  description = <<-EOT
    Certificates of the domains (ADR-0008): obtained and renewed by lego on each instance, through
    the ACME DNS-01 challenge, from any ACME directory (Let's Encrypt, or the organisation's
    authority). null runs the demonstration mode: a self-signed certificate, with a warning at
    every plan.
    - directory_url: the ACME directory, for example
      "https://acme-v02.api.letsencrypt.org/directory".
    - ca_bundle: root certificate (PEM) of an authority that is not publicly trusted.
    - email: contact of the ACME account.
    - dns.provider: a lego DNS provider code, for example "rfc2136".
    - dns.settings: for rfc2136, nameserver ("host:port"), tsig_key_name, tsig_algorithm and
      tsig_secret; for any other provider, its lego environment variables, as documented by lego.
    - dns.resolvers: name servers ("host:port") lego checks the TXT record on, and only on;
      empty uses the instance's resolvers and the zone's authoritative servers.
    The settings reach the instances through their user data, readable by the members of the
    project: give a key restricted to the _acme-challenge records of these domains.
  EOT
  type = object({
    directory_url = string
    ca_bundle     = optional(string)
    email         = string
    dns = object({
      provider  = string
      settings  = map(string)
      resolvers = optional(list(string), [])
    })
  })
  default   = null
  sensitive = true
}

variable "lego_version" {
  description = "Version of lego installed on the instances (release archive from GitHub), pinned."
  type        = string
  default     = "5.6.0"
}
