# Placement over availability zones (ADR-0012), with a mocked provider: no cloud is needed.

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
    defaults = { id = "00000000-0000-0000-0000-000000000031", cidr = "192.0.2.0/24" }
  }
}

variables {
  cloud            = "example"
  site             = "site-a"
  image            = "ubuntu-24.04"
  flavor           = "m1.small"
  boot_volume_size = 10
  public_network   = { network = "public", subnet = "public-subnet" }
  network_mtu      = 1362
  domains          = { "site-a.example.org" = { backends = ["198.51.100.21:443"] } }
  admin            = { users = { ops = ["ssh-ed25519 AAAA ops@example.org"] }, ssh_cidrs = ["192.0.2.0/24"] }
  bastion          = { external_network = { network = "intranet", subnet = "intranet" }, ssh_cidrs = ["192.0.2.0/24"] }
  plane_attachment = {
    publication = {
      mode         = "gateway"
      nat          = false
      cidr         = "192.0.2.0/24"
      network_id   = "00000000-0000-0000-0000-000000000001"
      network_name = "publication"
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
    condition     = alltrue([for i in values(module.edge.instances) : i.az == "az-1"])
    error_message = "With one zone, every instance must be in it."
  }
}

run "two_zones" {
  command = plan

  variables {
    zones        = ["az-1", "az-2"]
    volume_zones = { az-1 = "volumes-1", az-2 = "volumes-2" }
  }

  assert {
    condition     = [for n in ["site-a-edge-1", "site-a-edge-2"] : module.edge.instances[n].az] == ["az-1", "az-2"]
    error_message = "The two Traefik instances must be in two zones."
  }

  assert {
    condition     = module.edge.instances["site-a-edge-bastion"].az == "az-1" && local.boot_in["az-2"].az == "volumes-2"
    error_message = "The bastion must be in the first zone, and each root volume in the storage zone of its instance."
  }
}
