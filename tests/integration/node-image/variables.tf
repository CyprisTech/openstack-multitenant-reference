variable "site" {
  type = string
}

variable "az" {
  type = string
}

variable "flavor" {
  type = string
}

variable "image" {
  description = "Name of the node image built by images/kubernetes-node."
  type        = string
}

variable "admin_network" {
  type = object({ network = string, subnet = string })
}

variable "ssh_public_key" {
  type = string
}

variable "cloud" {
  type = string
}
