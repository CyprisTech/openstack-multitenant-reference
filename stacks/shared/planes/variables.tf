variable "cloud" {
  description = "Entry of clouds.yaml of the hub project: the project that owns the shared private planes."
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

variable "planes" {
  description = <<-EOT
    Shared planes, keyed by name (svc_public, monitoring, intranet).
    - mode "gateway": an external network provided by the cloud operator, adopted by name
      (network, subnet). Tenant routers join it with their gateway; nothing is created here.
    - mode "interface": a private network created in the hub project and shared with the
      attached projects by RBAC, with a transit router. Attached routers join it with an interface
      and reach each other through the transit router.
    - cidr: range of the plane.
    - mtu: MTU of a created plane; null uses the cloud default.
  EOT
  type = map(object({
    mode    = string
    cidr    = string
    network = optional(string)
    subnet  = optional(string)
    mtu     = optional(number)
  }))

  validation {
    condition     = alltrue([for p in values(var.planes) : contains(["gateway", "interface"], p.mode)])
    error_message = "A plane mode is \"gateway\" or \"interface\"."
  }

  validation {
    condition     = alltrue([for p in values(var.planes) : p.mode == "interface" ? true : p.network != null && p.subnet != null])
    error_message = "A gateway plane needs the network and subnet names of the operator's external network."
  }

  validation {
    condition     = alltrue([for p in values(var.planes) : can(cidrhost(p.cidr, 0)) && !strcontains(p.cidr, ":")])
    error_message = "Each plane needs an IPv4 cidr."
  }
}

variable "attachments" {
  description = <<-EOT
    Projects joining the planes, keyed by name.
    - project_id: project of the attachment (the target of the RBAC policies).
    - cidr: range of the attachment's network. Must not overlap a plane, nor another
      attachment of the same interface plane.
    - planes: the planes it joins, each with its role on that plane:
      - "shared": a shared service of the plane (the entry point on svc_public, the metrics
        receiver on monitoring, an internal service on intranet). It reaches the tenants and the other
        shared services of the plane, and they reach it.
      - "tenant": a workload, or a client of the shared services (the entry point pushes its
        metrics on monitoring). It reaches the shared services of the plane only.
  EOT
  type = map(object({
    project_id = string
    cidr       = string
    planes     = map(string)
  }))

  validation {
    condition     = alltrue(flatten([for a in values(var.attachments) : [for r in values(a.planes) : contains(["shared", "tenant"], r)]]))
    error_message = "The role of an attachment on a plane is \"shared\" or \"tenant\"."
  }

  validation {
    condition     = alltrue([for a in values(var.attachments) : can(cidrhost(a.cidr, 0)) && !strcontains(a.cidr, ":")])
    error_message = "Each attachment needs an IPv4 cidr."
  }

  validation {
    condition     = alltrue(flatten([for a in values(var.attachments) : [for p in keys(a.planes) : contains(keys(var.planes), p)]]))
    error_message = "Each plane of an attachment must be a key of planes."
  }
}

variable "tenant_ranges" {
  description = <<-EOT
    Per interface plane, aggregates covering the ranges of its tenants, routed by the shared
    services through the transit router: adding a tenant inside them changes no shared service.
    A plane absent here: the shared services get one route per tenant of the plane.
  EOT
  type        = map(list(string))
  default     = {}
}
