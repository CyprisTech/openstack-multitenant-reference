variable "cloud" {
  description = "Entry of clouds.yaml used by this stack (the shared-services project of the cluster)."
  type        = string
}

variable "site" {
  description = "Short site name; must match the site of the other stacks."
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
  default     = "10.36.0.0/24"
}

variable "dns_nameservers" {
  description = "DNS resolvers of the cluster network, reachable through its routes. They must resolve the endpoints of the cloud APIs (Cluster API, the cloud controller manager and Cinder CSI call them from the cluster), and public names for the images."
  type        = list(string)
  default     = []
}

variable "network_mtu" {
  description = <<-EOT
    MTU of the cluster network. It must not exceed the MTU the cloud can carry for tenant
    networks, nor the MTU of the planes the network joins (planes contract). The pod network
    uses this value minus the VXLAN overhead (ADR-0002, D4). null keeps the cloud default.
  EOT
  type        = number
  default     = null
}

variable "egress_network" {
  description = "External network giving the default route (packages, container images). The cluster gets no public address on it."
  type        = object({ network = string, subnet = string })
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

variable "admin_network" {
  description = <<-EOT
    Administration network carrying the floating IPs of the Kubernetes API and of the bootstrap
    instance (ADR-0002, D6). null uses the internal services plane for this role, which requires an
    operator plane (gateway mode): then admin.sources must be specific addresses, never the range
    of the plane.
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
    - control_plane_root_volume_size, worker_root_volume_size: GiB of the root volume of each
      machine (container images, ephemeral storage, logs, and etcd on the control plane). They
      must not be smaller than the virtual size of the node image.
    - domains: names of the HTTP services, served by the internal ingress, with a certificate.
    - pod_cidr, service_cidr: must not overlap the cluster network nor the planes.
  EOT
  type = object({
    name                           = optional(string, "shared")
    node_image                     = string
    kubernetes_version             = optional(string, "v1.36.5")
    control_plane_flavor           = string
    worker_flavor                  = string
    control_plane_count            = optional(number, 3)
    worker_count                   = optional(number, 2)
    control_plane_root_volume_size = optional(number, 30)
    worker_root_volume_size        = optional(number, 40)
    domains                        = optional(list(string), ["services.example.org"])
    pod_cidr                       = optional(string, "10.244.0.0/16")
    service_cidr                   = optional(string, "10.96.0.0/12")
  })

  validation {
    condition     = contains([1, 3, 5], var.cluster.control_plane_count)
    error_message = "control_plane_count must be 1, 3 or 5 (an odd number for etcd)."
  }
}

variable "monitoring" {
  description = <<-EOT
    Monitoring as a push integration point (ADR-0007): the Prometheus of the cluster pushes to
    the receiver through the observability plane (remote write). Nothing connects into the cluster
    for its metrics.
    - receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output
      receiver_url of the receiver); null keeps the metrics in the cluster.
  EOT
  type = object({
    receiver = optional(string)
  })
  default = {}
}

variable "certificates" {
  description = <<-EOT
    Certificates of the domains of the cluster (ADR-0008): cert-manager obtains and renews them
    through the ACME DNS-01 challenge, from any ACME directory (Let's Encrypt, or the
    organisation's authority), and writes the secret of the ingress listener. null runs the
    demonstration mode: a self-signed certificate, with a warning at every plan.
    - directory_url, ca_bundle (PEM, for an authority that is not publicly trusted), email.
    - dns.provider "rfc2136" with dns.settings nameserver ("host:port"), tsig_key_name,
      tsig_algorithm, tsig_secret: the stack writes the TSIG secret in the cert-manager
      namespace. Any other provider: dns.solver, a cert-manager dns01 solver, whose credentials
      Secret you create in the cert-manager namespace.
    - dns.resolvers: name servers ("host:port") cert-manager checks the TXT record on; empty
      uses the cluster's resolvers.
    The settings reach the cluster through the bootstrap instance's user data, readable by the
    members of the project: give a key restricted to the _acme-challenge records of the domains.
  EOT
  type = object({
    directory_url = string
    ca_bundle     = optional(string)
    email         = string
    dns = object({
      provider  = string
      settings  = optional(map(string), {})
      solver    = optional(any)
      resolvers = optional(list(string), [])
    })
  })
  default   = null
  sensitive = true
}

variable "consumers" {
  description = <<-EOT
    Who may use the services of the cluster on the internal services plane: the internal_sources
    output of each consuming tenant (its router's gateway address on a plane with NAT, its range
    otherwise). Admitted by the internal ingress and the layer 4 services, nothing else is.
  EOT
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.consumers : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "consumers are CIDRs, without a default route (/0)."
  }
}

variable "service_addresses" {
  description = <<-EOT
    Host numbers, in the cluster network, of the entries on a plane without NAT: the internal
    ingress and the demonstrated TCP service. Neutron does not allocate the host numbers below
    reserved_hosts to anything else, so these addresses are known before the cluster exists.
  EOT
  type = object({
    ingress        = optional(number, 10)
    echo           = optional(number, 11)
    reserved_hosts = optional(number, 32)
  })
  default = {}
}
