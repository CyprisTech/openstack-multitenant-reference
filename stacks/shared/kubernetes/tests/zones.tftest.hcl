# Placement over availability zones (ADR-0012), with a mocked provider: no cloud is needed.
# The Cluster API manifests are rendered by OpenTofu, so the test reads them.

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
    domains              = ["services.example.org"]
  }
  certificates = {
    directory_url = "https://acme.example.org/directory"
    email         = "ops@example.org"
    dns = {
      provider = "rfc2136"
      settings = { nameserver = "192.0.2.53:53", tsig_key_name = "acme", tsig_algorithm = "hmac-sha256", tsig_secret = "c2VjcmV0" }
    }
  }
  plane_attachment = {
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

run "one_zone" {
  command = plan


  variables {
    zones = ["az-1"]
  }

  assert {
    condition     = strcontains(module.cluster.manifests["cluster.yaml"], "name: md-0\n        failureDomain: az-1\n        replicas: 4") && !strcontains(module.cluster.manifests["cluster.yaml"], "md-1")
    error_message = "With one zone, the workers must be one machine deployment in it."
  }
}

run "three_zones" {
  command = plan


  variables {
    zones = ["az-1", "az-2", "az-3"]
  }

  assert {
    condition = alltrue([
      strcontains(module.cluster.manifests["cluster.yaml"], "name: md-0\n        failureDomain: az-1\n        replicas: 2"),
      strcontains(module.cluster.manifests["cluster.yaml"], "name: md-1\n        failureDomain: az-2\n        replicas: 1"),
      strcontains(module.cluster.manifests["cluster.yaml"], "name: md-2\n        failureDomain: az-3\n        replicas: 1"),
    ])
    error_message = "Four workers over three zones must be two, one and one machines, one machine deployment per zone."
  }

  assert {
    condition     = strcontains(module.cluster.manifests["cluster-class.yaml"], "controlPlaneAvailabilityZones:\n      - az-1\n      - az-2\n      - az-3\n")
    error_message = "The control plane must be spread over every zone."
  }
}
