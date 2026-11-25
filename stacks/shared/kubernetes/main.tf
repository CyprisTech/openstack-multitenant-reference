# The shared cluster, a Kubernetes cluster for shared services (spec: a Kubernetes cluster for
# shared services): the same cluster as the published cluster (modules/kubernetes-cluster), in a
# shared-services project, attached with the role shared on the internal services plane. It
# offers services to the tenants that consume them, through an internal ingress for HTTP and
# layer 4 Services, admitted to the consumers only; it is not published on the publication plane.
# Its Prometheus pushes to the receiver through the observability plane.

locals {
  # Closed by default: an empty list of source ranges would admit every source.
  sources = length(var.consumers) > 0 ? var.consumers : [var.cluster_cidr]
}

module "cluster" {
  source = "../../../modules/kubernetes-cluster"

  name   = "${var.site}-shared"
  planes = ["internal", "observability"]

  # HTTP services: one HTTPRoute each on the internal ingress, its own Traefik and Gateway,
  # separate from any public ingress.
  ingresses = {
    internal = {
      plane   = "internal"
      sources = local.sources
      domains = var.cluster.domains
      host    = var.service_addresses.ingress
    }
  }

  # The demonstrated layer 4 service (demo/echo.yaml): a TCP echo, selected by its label; and
  # the layer 4 services you declare, on the internal services plane too.
  services = merge({
    echo = {
      plane     = "internal"
      namespace = "echo"
      selector  = { app = "echo" }
      ports     = [7000]
      sources   = local.sources
      host      = var.service_addresses.echo
    }
    }, { for k, s in var.services : k => {
      plane     = "internal"
      namespace = s.namespace
      selector  = s.selector
      ports     = s.ports
      sources   = s.sources != null ? s.sources : local.sources
      host      = s.host
  } })
  reserved_hosts = var.service_addresses.reserved_hosts

  site             = var.site
  zones            = var.zones
  volume_zones     = var.volume_zones
  image            = var.image
  flavor           = var.flavor
  boot_volume_size = var.boot_volume_size
  cluster_cidr     = var.cluster_cidr
  dns_nameservers  = var.dns_nameservers
  network_mtu      = var.network_mtu
  egress_network   = var.egress_network
  plane_attachment = var.plane_attachment
  admin_network    = var.admin_network
  admin            = var.admin
  bootstrap        = var.bootstrap
  cluster          = var.cluster
  monitoring       = var.monitoring
  certificates     = var.certificates
}

# The names of the HTTP services, in the zone of the internal names, when the cloud has Designate
# and the zone is owned by or shared with this project (ADR-0010, D3): dns = "designate". With
# dns = "output", none is written; the dns_records output gives them in both cases (ADR-0016, D2).
module "names" {
  count  = var.internal_zone != null && var.dns == "designate" ? 1 : 0
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/dns?ref=v0.1.6"

  records = {
    for d in var.cluster.domains : d => {
      zone_id   = var.internal_zone.id
      zone_name = var.internal_zone.name
      name      = trimsuffix(d, ".${trimsuffix(var.internal_zone.name, ".")}")
      type      = "A"
      records   = [module.cluster.entries.internal]
      ttl       = var.internal_zone.ttl
    }
  }
}

# The host numbers of the entries on a plane without NAT are distinct: two load balancers cannot
# request the same address.
resource "terraform_data" "service_hosts" {
  lifecycle {
    precondition {
      condition     = length(compact([for h in concat([var.service_addresses.ingress, var.service_addresses.echo], [for s in var.services : s.host]) : h == null ? "" : tostring(h)])) == length(distinct(compact([for h in concat([var.service_addresses.ingress, var.service_addresses.echo], [for s in var.services : s.host]) : h == null ? "" : tostring(h)])))
      error_message = "The host numbers of the ingress, the echo and the services must be distinct."
    }
  }
}
