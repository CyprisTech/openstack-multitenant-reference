# Kubernetes tenant: a Kubernetes cluster created by Cluster API with the OpenStack provider
# (ADR-0002), in a tenant project, published through the shared entry point, exposed directly with
# its own public floating IP (ADR-0006, D2), or private, with no ingress (ADR-0016, D1). The
# cluster itself is built by modules/kubernetes-cluster.

locals {
  public  = var.exposure == "public"
  exposed = var.exposure != "none"
}

module "cluster" {
  source = "../../../modules/kubernetes-cluster"

  name = "${var.site}-published"
  # The publication plane only through the entry point; the internal services plane when the
  # stack's attachment has it.
  planes = concat(var.exposure == "entry-point" ? ["publication"] : [], ["observability"], contains(keys(var.plane_attachment), "internal") ? ["internal"] : [])

  # The tenant's service address (ADR-0006, D1): its public ingress, reached by the entry point
  # only, which sends a PROXY protocol header; or, exposed directly, a floating IP of
  # egress_network reached from anywhere. A private cluster has no ingress.
  ingresses = { for k, v in {
    public = {
      plane          = local.public ? "egress" : "publication"
      sources        = local.public ? ["0.0.0.0/0"] : var.edge_sources
      proxy_protocol = !local.public
      domains        = var.cluster.domains
      namespace      = "traefik"
      tls_secret     = "published-tls"
      host           = var.service_addresses.ingress
    }
  } : k => v if local.exposed }
  # The layer 4 services you declare: each one at a public floating IP of egress_network.
  services = { for k, s in var.services : k => {
    plane     = "egress"
    namespace = s.namespace
    selector  = s.selector
    ports     = s.ports
    sources   = s.sources
  } }
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

resource "terraform_data" "exposure" {
  lifecycle {
    precondition {
      condition     = var.exposure != "none" || length(var.services) == 0
      error_message = "A private cluster (exposure = \"none\") has no entry: services must be empty."
    }
    precondition {
      condition     = var.exposure != "entry-point" || length(var.edge_sources) > 0
      error_message = "exposure = \"entry-point\" needs edge_sources: output publication_sources of stack shared/entry-point."
    }
  }
}
