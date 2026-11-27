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

variable "name" {
  description = "Name of the shared service, in the names of its resources (<site>-<name>) and in the labels of its metrics. Two shared services of one site need two names."
  type        = string
  default     = "service"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.name))
    error_message = "name must be 1 to 16 lowercase letters, digits or dashes, starting with a letter."
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

variable "cidr" {
  description = "Range of the service's network. On a hub plane, the attachment's cidr in shared/planes; on a plane without NAT it must be unique (stack shared/planes checks it)."
  type        = string
  default     = "10.35.0.0/27"
}

variable "dns_nameservers" {
  description = "DNS resolvers of the service's network, reachable through its routes; empty (the default), those of Neutron's DHCP. A service without egress takes a resolver behind one of its planes (ADR-0016, D3)."
  type        = list(string)
  default     = []
}

variable "egress" {
  description = <<-EOT
    How the service reaches the Internet (ADR-0016, D1), for its packages, the ACME directory and
    the metrics agent:
    - "router": its own router to egress_network, which takes the default route;
    - "shared": the shared egress of the landing zone (stack shared/egress), through the proxy of
      shared_egress, for the names the service is declared with there;
    - "none": no default route, no package: an image that holds the workload already, and an ACME
      directory and a receiver reached through the planes.
    Required: what a shared service reaches is declared.
  EOT
  type        = string

  validation {
    condition     = contains(["router", "shared", "none"], var.egress)
    error_message = "egress must be \"router\", \"shared\" or \"none\"."
  }

  validation {
    condition     = var.egress != "shared" || var.shared_egress != null
    error_message = "egress = \"shared\" needs shared_egress."
  }

  validation {
    condition     = var.egress != "none" || (var.workload != null && var.certificates == null)
    error_message = "egress = \"none\" installs nothing: it needs a workload from the image (workload, with no packages) and no certificates (lego is installed from its release archive)."
  }
}

variable "shared_egress" {
  description = "The shared egress of the landing zone, with egress = \"shared\": proxy, the URL of the proxy output of stack shared/egress, where this service is declared with its internal_sources and its names (ADR-0016, D1)."
  type = object({
    proxy = string
  })
  default = null
}

variable "egress_network" {
  description = "External network of the egress router (egress = \"router\"). The instances get no public address on it. subnet: optional, the subnet of that network to look up by name; without it, Neutron chooses (a public network with several subnets of the same name). null with egress = \"none\"."
  type = object({
    network = string
    subnet  = optional(string)
  })
  default = null

  validation {
    condition     = var.egress != "router" || var.egress_network != null
    error_message = "egress = \"router\" needs egress_network."
  }
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
    routes = optional(list(object({
      destination = string
      next_hop    = string
    })), [])
  }))

  validation {
    condition     = contains(keys(var.plane_attachment), "internal")
    error_message = "A shared service joins the internal services plane: plane_attachment needs internal (role shared in shared/planes)."
  }
}

variable "instance_count" {
  description = "Number of instances, spread over the zones. Above one, an internal load balancer per service is its address (ADR-0006, D1); with one, the instance itself."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1."
  }
}

variable "consumers" {
  description = <<-EOT
    Who may use the services on the internal services plane, as CIDRs: the internal_sources output
    of each consuming tenant, and the ranges of the users as the service sees them. Admitted on the
    ports of the services only. Empty keeps the services closed, as when the service is created
    before its consumers. Network admission does not identify a user: authentication belongs to
    the service.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.consumers : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "consumers are CIDRs, without a default route (/0)."
  }
}

variable "services" {
  description = <<-EOT
    The services offered on the internal services plane, keyed by name, each at its own address:
    an internal load balancer with a TCP listener per port when there are several instances, the
    instance itself otherwise.
    - ports: the TCP ports the workload listens on.
    - sources: who may connect; the consumers by default.
    - domains: the names of the service: records in internal_zone, and the names of the
      certificate of the instances.
    The default is the demonstration: HTTP on 8080 (HTTPS with certificates).
  EOT
  type = map(object({
    ports   = list(number)
    sources = optional(list(string))
    domains = optional(list(string), [])
  }))
  default = { demo = { ports = [8080] } }

  validation {
    condition     = length(var.services) > 0 && alltrue([for s in var.services : length(s.ports) > 0])
    error_message = "services needs at least one service, each with at least one port."
  }
  validation {
    condition     = alltrue([for s in var.services : s.sources == null || alltrue([for c in s.sources : can(cidrhost(c, 0)) && !endswith(c, "/0")])])
    error_message = "services sources are CIDRs, without a default route (/0): the plane is shared."
  }
  validation {
    condition     = length(flatten([for s in var.services : s.ports])) == length(distinct(flatten([for s in var.services : s.ports])))
    error_message = "Two services cannot listen on the same port: the instances serve them all."
  }
}

variable "workload" {
  description = <<-EOT
    The workload, added to the cloud-init of each instance (the form of the tenant module's
    cloudinit): packages to install, files to write (path => { content, permissions, owner }),
    commands to run at first boot. The stack does not template it: a setting that depends on the
    instance reads the instance metadata. null runs the demonstration on the ports of services:
    HTTP, or HTTPS with the certificate of the instance.
  EOT
  type = object({
    packages = optional(list(string), [])
    write_files = optional(map(object({
      content     = string
      permissions = optional(string)
      owner       = optional(string)
    })), {})
    runcmd = optional(list(string), [])
  })
  default = null
}

variable "tls_reload" {
  description = "Command the ACME client runs after each issuance and renewal, for the workload to load the certificate (/etc/shared-service/tls/cert.pem and key.pem). null: the demonstration's restart, or nothing with your workload."
  type        = string
  default     = null
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
    Optional administration bastion. By default it lives in its own small network whose router joins
    external_network (an administration network such as an intranet) and carries a floating
    IP on it. A second port on the service's network gives it access to the instances; the
    network itself gets no route to the administration network.
    var.bastion_placement may put it on the stack's network instead (ADR-0014, D2).
    - ssh_cidrs: sources allowed to reach the bastion on port 22.
    The users of var.admin are created on the bastion and on the instances.
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
    Monitoring as a push integration point (ADR-0007): each instance runs its exporters and a
    Prometheus agent that pushes to the receiver through the observability plane. Nothing connects
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
    Certificates of the domains of the services (ADR-0008): obtained and renewed by lego on each instance, through
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
    error_message = "bastion_placement \"stack-network\" needs bastion.external_network to be the egress_network (ADR-0014, D2)."
  }
}

variable "dns" {
  description = "Where the records of internal_zone go (ADR-0016, D2): \"designate\", written in the cloud's Designate, or \"output\", written nowhere, for your DNS provider. The dns_records output gives them in both cases."
  type        = string
  default     = "designate"

  validation {
    condition     = contains(["designate", "output"], var.dns)
    error_message = "dns is \"designate\" or \"output\"."
  }
}

variable "internal_zone" {
  description = <<-EOT
    Zone of the internal names: the records of the domains of services, in the dns_records output. With
    dns = "designate", the stack writes them in this Designate zone, owned by or shared with this
    project. null: no records, the domains output gives the names and their address.
    - name (with its trailing dot): the zone; id: its Designate ID, needed with dns = "designate".
    - ttl: of the records.
  EOT
  type = object({
    id   = optional(string)
    name = string
    ttl  = optional(number, 300)
  })
  default = null

  validation {
    condition     = var.internal_zone == null || var.dns != "designate" || try(var.internal_zone.id != null, false)
    error_message = "internal_zone.id is needed to write the records in Designate (dns = \"designate\")."
  }

  validation {
    condition = var.internal_zone == null || alltrue([
      for d in flatten([for s in var.services : s.domains]) : endswith(d, ".${trimsuffix(try(var.internal_zone.name, "."), ".")}")
    ])
    error_message = "Every name of the domains of services must be in internal_zone."
  }
}
