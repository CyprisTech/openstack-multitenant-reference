variable "cloud" { type = string }

variable "site" { type = string }

variable "az" { type = string }

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
  description = "Range of the service's network; on a hub plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.35.0.0/28"
}

variable "allowed_sources" {
  description = "Sources admitted on port 8080: output internal_sources of the Kubernetes tenant."
  type        = list(string)
}

variable "ssh_cidrs" { type = list(string) }

variable "ssh_keys" { type = list(string) }
