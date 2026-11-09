# Kubernetes cluster for shared services (spec: a Kubernetes cluster for shared services): the same
# cluster as the Kubernetes tenant (modules/kubernetes-cluster), in a shared-services project,
# attached with the role shared on the internal services plane. It offers services to the tenants
# that consume them, through an internal ingress for HTTP and layer 4 Services, admitted to the
# consumers only; it is not published on the publication plane. Its Prometheus pushes to the
# receiver through the observability plane.

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

  # The demonstrated layer 4 service (demo/echo.yaml): a TCP echo, selected by its label.
  services = {
    echo = {
      plane     = "internal"
      namespace = "echo"
      selector  = { app = "echo" }
      ports     = [7000]
      sources   = local.sources
      host      = var.service_addresses.echo
    }
  }
  reserved_hosts = var.service_addresses.reserved_hosts

  site             = var.site
  az               = var.az
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
