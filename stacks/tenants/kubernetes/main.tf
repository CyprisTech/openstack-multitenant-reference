# Kubernetes tenant: a Kubernetes cluster created by Cluster API with the OpenStack provider
# (ADR-0002), in a tenant project, published on the publication plane through the entry point.
# The cluster itself is built by modules/kubernetes-cluster.

module "cluster" {
  source = "../../../modules/kubernetes-cluster"

  name   = "${var.site}-published"
  planes = ["publication", "observability", "internal"]

  # The tenant's service address (ADR-0006, D1): its public ingress, reached by the entry point
  # only, which sends a PROXY protocol header.
  ingresses = {
    public = {
      plane          = "publication"
      sources        = var.edge_sources
      proxy_protocol = true
      domains        = var.cluster.domains
      namespace      = "traefik"
      tls_secret     = "published-tls"
      host           = var.service_addresses.ingress
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
