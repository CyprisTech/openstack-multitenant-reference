# Exposure of the cluster (ADR-0006, D2; ADR-0016, D1), with a mocked provider: no cloud is
# needed. The Cluster API manifests are rendered by OpenTofu, so the test reads them.

mock_provider "openstack" {
  mock_resource "openstack_networking_port_v2" {
    defaults = { all_fixed_ips = ["192.0.2.10"] }
  }
  mock_resource "openstack_networking_floatingip_v2" {
    defaults = { address = "203.0.113.10" }
  }
  mock_resource "openstack_lb_loadbalancer_v2" {
    defaults = { vip_address = "192.0.2.20", vip_port_id = "00000000-0000-0000-0000-000000000020" }
  }
  mock_data "openstack_networking_network_v2" {
    defaults = { id = "00000000-0000-0000-0000-000000000030" }
  }
  mock_data "openstack_networking_subnet_v2" {
    defaults = { id = "00000000-0000-0000-0000-000000000031", cidr = "203.0.113.0/24" }
  }
}

variables {
  cloud          = "example"
  exposure       = "entry-point"
  site           = "site-a"
  image          = "ubuntu-24.04"
  flavor         = "m1.medium"
  egress_network = { network = "public", subnet = "public" }
  network_mtu    = 1362
  admin_network  = { network = "intranet", subnet = "intranet", cidr = "203.0.113.0/24" }
  admin          = { users = { ops = ["ssh-ed25519 AAAA ops@example.org"] }, sources = ["192.0.2.10/32"] }
  cluster = {
    node_image           = "ubuntu-2404-kube-v1.36.5"
    control_plane_flavor = "m1.medium"
    worker_flavor        = "m1.medium"
    worker_count         = 4
    domains              = ["apps.example.org"]
  }
  certificates = {
    directory_url = "https://acme.example.org/directory"
    email         = "ops@example.org"
    dns = {
      provider = "rfc2136"
      settings = { nameserver = "192.0.2.53:53", tsig_key_name = "acme", tsig_algorithm = "hmac-sha256", tsig_secret = "c2VjcmV0" }
    }
  }
  zones = ["az-1"]
  plane_attachment = {
    publication = {
      mode         = "gateway"
      nat          = false
      cidr         = "198.18.0.0/24" # a test range, apart from the other planes
      network_id   = "00000000-0000-0000-0000-000000000005"
      network_name = "publication"
      subnet_id    = "00000000-0000-0000-0000-000000000006"
    }
    internal = {
      mode         = "gateway"
      nat          = false
      cidr         = "192.0.2.0/24"
      network_id   = "00000000-0000-0000-0000-000000000001"
      network_name = "internal"
      subnet_id    = "00000000-0000-0000-0000-000000000002"
    }
    observability = {
      mode         = "gateway"
      nat          = false
      cidr         = "198.51.100.0/24"
      network_id   = "00000000-0000-0000-0000-000000000003"
      network_name = "observability"
      subnet_id    = "00000000-0000-0000-0000-000000000004"
    }
  }
}

run "private_cluster" {
  command = plan

  variables {
    exposure = "none"
  }

  assert {
    condition     = length(module.cluster.entries) == 0 && output.service_address == null
    error_message = "A private cluster has no ingress and no service address."
  }

  assert {
    condition     = length(output.published_domains) == 0 && length(output.edge_sources) == 0
    error_message = "A private cluster publishes nothing through the entry point."
  }

  assert {
    condition     = !strcontains(module.cluster.manifests["addons.yaml"], "namespace: traefik")
    error_message = "A private cluster deploys no ingress."
  }
}

run "published_through_the_entry_point" {
  command = plan

  variables {
    exposure     = "entry-point"
    edge_sources = ["198.51.100.5/32"]
  }

  assert {
    condition     = length(module.cluster.entries) == 1 && contains(keys(module.cluster.entries), "public") && contains(keys(output.published_domains), "apps.example.org")
    error_message = "Through the entry point, the cluster has its ingress and publishes its domains."
  }

  assert {
    condition     = strcontains(module.cluster.manifests["addons.yaml"], "namespace: traefik")
    error_message = "Through the entry point, the cluster deploys its ingress."
  }
}

# Layer 4 services of the tenant: at a public floating IP of egress_network; none on a private
# cluster.
run "declared_services" {
  command = plan

  variables {
    exposure     = "entry-point"
    edge_sources = ["198.51.100.5/32"]
    services     = { game = { namespace = "game", selector = { app = "game" }, ports = [7777], sources = ["0.0.0.0/0"] } }
  }

  assert {
    condition     = contains(keys(module.cluster.entries), "game") && keys(output.services) == ["game"]
    error_message = "A declared service is an entry of the cluster."
  }
}

run "no_service_on_a_private_cluster" {
  command = plan

  variables {
    exposure = "none"
    services = { game = { namespace = "game", selector = { app = "game" }, ports = [7777], sources = ["0.0.0.0/0"] } }
  }

  expect_failures = [terraform_data.exposure]
}
