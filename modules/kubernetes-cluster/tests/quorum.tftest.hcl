# The zones of the Kubernetes module, with a mocked provider (no cloud is needed): the quorum
# warning of the control plane (ADR-0012) and the storage of the persistent volumes.

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
  name           = "shared"
  planes         = ["internal", "observability"]
  site           = "site-a"
  image          = "ubuntu-24.04"
  flavor         = "m1.medium"
  egress_network = { network = "public", subnet = "public" }
  network_mtu    = 1362
  admin_network  = { network = "intranet", subnet = "intranet", cidr = "203.0.113.0/24" }
  admin          = { users = { ops = ["ssh-ed25519 AAAA ops@example.org"] }, sources = ["192.0.2.10/32"] }
  cluster = {
    name                 = "shared"
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

run "three_zones" {
  command = plan

  variables {
    zones = ["az-1", "az-2", "az-3"]
  }
}

run "two_zones" {
  command = plan

  variables {
    zones = ["az-1", "az-2"]
  }

  # Three control plane nodes over two zones: the quorum does not survive the loss of a zone.
  expect_failures = [check.control_plane_quorum]
}

run "shared_storage" {
  command = plan

  variables {
    zones        = ["az-1", "az-2", "az-3"]
    volume_zones = { az-1 = "nova", az-2 = "nova", az-3 = "nova" }
  }

  assert {
    condition     = strcontains(output.scripts["create-cluster.sh"], "ignore-volume-az=true") && strcontains(output.scripts["create-cluster.sh"], "availability: nova")
    error_message = "One storage zone for every zone is shared storage: ignore-volume-az and the storage zone in the class."
  }
}

run "storage_per_zone" {
  command = plan

  variables {
    zones        = ["az-1", "az-2", "az-3"]
    volume_zones = { az-1 = "az-1", az-2 = "az-2", az-3 = "az-3" }
  }

  assert {
    condition     = !strcontains(output.scripts["create-cluster.sh"], "ignore-volume-az") && !strcontains(output.scripts["create-cluster.sh"], "availability:")
    error_message = "Storage zones of the same names: volumes in the zone of their node."
  }
}

run "storage_zones_unsupported" {
  command = plan

  variables {
    zones        = ["az-1", "az-2", "az-3"]
    volume_zones = { az-1 = "ceph-1", az-2 = "ceph-2", az-3 = "ceph-3" }
  }

  expect_failures = [check.volume_zones]
}
