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
  boot_volume_size = 8
  network_mtu      = 1362
  monitoring       = { receiver = "http://203.0.113.10:9090" }
  admin            = { users = { ops = ["ssh-ed25519 AAAA ops@example.org"] } }
  bastion          = { external_network = { network = "intranet", subnet = "intranet" }, ssh_cidrs = ["192.0.2.0/24"] }
  plane_attachment = {
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

run "first_zone" {
  command = plan

  variables {
    zones        = ["az-1", "az-2"]
    volume_zones = { az-1 = "volumes-1" }
  }

  assert {
    condition     = alltrue([for i in values(module.isolated.instances) : i.az == "az-1"]) && local.boot_in.az == "volumes-1"
    error_message = "The workload and its bastion must be in the first zone, with their root volumes in its storage zone."
  }
}
