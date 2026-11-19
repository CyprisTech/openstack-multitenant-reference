variable "cloud" { type = string }

variable "site" { type = string }

variable "zones" {
  description = "Availability zones; the fixture runs in the first one, as the single instances of the stacks."
  type        = list(string)
}

variable "image" { type = string }

variable "flavor" { type = string }

variable "boot_volume_size" {
  type    = number
  default = null
}

variable "network_mtu" {
  type    = number
  default = null
}

variable "dns_nameservers" {
  type    = list(string)
  default = []
}

variable "plane_attachment" {
  description = "The service's entry of the attachments output of stack shared/planes (role shared on internal)."
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

variable "cidr" {
  description = "Range of the authority's network; on a hub plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.37.0.0/28"
}

variable "egress_network" {
  description = "External network giving the default route (package download)."
  type        = object({ network = string, subnet = string })
}

variable "bastion" {
  description = "Administration bastion: floating IP on external_network, SSH from ssh_cidrs. Where it lives: var.bastion_placement."
  type = object({
    external_network = object({ network = string, subnet = string })
    ssh_cidrs        = list(string)
  })
}

variable "users" {
  description = "SSH users (login => public keys, sudo granted), on the bastion and the authority."
  type        = map(list(string))
}

variable "zone" {
  description = "The test zone served by Knot; the tenants' names are under it."
  type        = string
  default     = "example.org"
}

variable "tenants" {
  description = <<-EOT
    The tenants that obtain certificates, keyed by tenant name, with the names (domains) each may
    get a certificate for. Each tenant gets its own TSIG key, allowed to update only the TXT
    records _acme-challenge.<name> of its names.
  EOT
  type        = map(list(string))
  validation {
    condition = alltrue(flatten([for names in values(var.tenants) : [
      for n in names : n == var.zone || endswith(n, ".${var.zone}")
    ]]))
    error_message = "Every name must be in the test zone."
  }
}

variable "step_version" {
  description = "Versions of step-ca and step-cli (Debian packages of the smallstep releases), pinned."
  type        = object({ ca = string, cli = string })
  default     = { ca = "0.30.2", cli = "0.31.0" }
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
