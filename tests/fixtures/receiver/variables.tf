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
  description = "The service's entry of the attachments output of stack shared/planes (role shared on observability)."
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
  description = "Range of the receiver's network; on a hub plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.34.0.0/28"
}

variable "egress_network" {
  description = "External network giving the default route (package and image download)."
  type        = object({ network = string, subnet = string })
}

variable "bastion" {
  description = "Administration bastion: floating IP on external_network, SSH from ssh_cidrs. placement: \"own-network\" (default) or \"stack-network\" when external_network is the egress network (ADR-0014, D2)."
  type = object({
    external_network = object({ network = string, subnet = string })
    placement        = optional(string, "own-network")
    ssh_cidrs        = list(string)
  })

  validation {
    condition     = var.bastion == null || try(var.bastion.placement, "own-network") != "stack-network" || try(var.bastion.external_network.network == var.egress_network.network, false)
    error_message = "bastion.placement \"stack-network\" needs bastion.external_network to be the egress_network (ADR-0014, D2)."
  }

  validation {
    condition     = var.bastion == null || contains(["own-network", "stack-network"], try(var.bastion.placement, "own-network"))
    error_message = "bastion.placement is \"own-network\" or \"stack-network\"."
  }
}

variable "users" {
  description = "SSH users (login => public keys, sudo granted), on the bastion and the receiver."
  type        = map(list(string))
}

variable "prometheus_image" {
  description = "Prometheus image, pinned."
  type        = string
  default     = "docker.io/prom/prometheus:v3.15.1"
}
