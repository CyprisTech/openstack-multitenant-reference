variable "cloud" {
  description = "Entry of clouds.yaml used by this stack (the platform project)."
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
  description = "Availability zone of the bootstrap instance and of the cluster machines."
  type        = string
}

variable "image" {
  description = "Image name of the bootstrap instance (an Ubuntu LTS cloud image)."
  type        = string
}

variable "flavor" {
  description = "Flavor name of the bootstrap instance (kind runs there: 2 vCPU and 4 GiB at least)."
  type        = string
}

variable "boot_volume_size" {
  description = "Size in GiB of the root volume of the bootstrap instance; null boots from the flavor's local disk."
  type        = number
  default     = null
}

variable "cluster_cidr" {
  description = "Range of the cluster network (nodes, load balancer VIPs, bootstrap instance)."
  type        = string
  default     = "10.24.0.0/24"
}

variable "dns_nameservers" {
  description = "DNS resolvers of the cluster network, reachable through its routes."
  type        = list(string)
  default     = []
}

variable "network_mtu" {
  description = <<-EOT
    MTU of the cluster network. It must not exceed the MTU the cloud can carry for tenant
    networks, nor the MTU of the planes the network joins (layer 10 contract). The pod network
    uses this value minus the VXLAN overhead (ADR-0002, D4). null keeps the cloud default.
  EOT
  type        = number
  default     = null
}

variable "egress_network" {
  description = "External network giving the default route (packages, container images). The cluster gets no public address on it."
  type        = object({ network = string, subnet = string })
}

variable "planes" {
  description = "Shared planes joined by the platform (layer 10 contract): network and subnet names, and the range advertised by DHCP."
  type = object({
    svc_public = object({ network = string, subnet = string, cidr = string })
    monitoring = object({ network = string, subnet = string, cidr = string })
    intranet   = object({ network = string, subnet = string, cidr = string })
  })
}

variable "admin_network" {
  description = <<-EOT
    Administration network carrying the floating IPs of the Kubernetes API and of the bootstrap
    instance (ADR-0002, D6). null uses the intranet plane for this role: then admin.sources must
    be specific addresses, never the range of the intranet.
  EOT
  type        = object({ network = string, subnet = string, cidr = string })
  default     = null
}

variable "admin" {
  description = <<-EOT
    Administration access.
    - users: login => SSH public keys, created on the bootstrap instance with sudo.
    - sources: addresses of the operators as seen on the administration network (with source NAT,
      the address of a router). They reach the bootstrap instance on port 22 and the Kubernetes
      API on port 6443, and nothing else does.
    - ssh_key_name: Nova key pair injected in the cluster machines, or null for none.
  EOT
  type = object({
    users        = optional(map(list(string)), {})
    sources      = list(string)
    ssh_key_name = optional(string)
  })

  validation {
    condition     = length(var.admin.sources) > 0 && alltrue([for c in var.admin.sources : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "admin.sources needs at least one CIDR, and no default route (/0)."
  }
}

variable "bootstrap" {
  description = "Create the bootstrap instance. Set to false once the cluster manages itself (ADR-0002, D3); set back to true before tearing the cluster down."
  type        = bool
  default     = true
}

variable "cluster" {
  description = <<-EOT
    The Kubernetes cluster created by Cluster API.
    - node_image: name of the image built by images/kubernetes-node.
    - kubernetes_version: must match the node image.
    - control_plane_count: 3 for a highly available control plane.
    - root_volume_size: GiB of the root volume of each machine (flavors without local disk).
    - domains: domains served by the ingress and published through the entry point.
    - pod_cidr, service_cidr: must not overlap the cluster network nor the planes.
  EOT
  type = object({
    name                 = optional(string, "platform")
    node_image           = string
    kubernetes_version   = optional(string, "v1.36.5")
    control_plane_flavor = string
    worker_flavor        = string
    control_plane_count  = optional(number, 3)
    worker_count         = optional(number, 2)
    root_volume_size     = optional(number, 20)
    domains              = optional(list(string), ["apps.example.org"])
    pod_cidr             = optional(string, "10.244.0.0/16")
    service_cidr         = optional(string, "10.96.0.0/12")
  })

  validation {
    condition     = contains([1, 3, 5], var.cluster.control_plane_count)
    error_message = "control_plane_count must be 1, 3 or 5 (an odd number for etcd)."
  }
}

variable "monitoring" {
  description = <<-EOT
    Exposure of the in-cluster Prometheus to the collector (ADR-0002, D5): a load balancer whose
    VIP gets a floating IP of the monitoring plane, admitted from collector_cidrs only.
    - collector_cidrs: addresses of the collector as seen by the platform.
  EOT
  type = object({
    collector_cidrs = list(string)
  })
}
