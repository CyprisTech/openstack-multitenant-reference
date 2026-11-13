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
  egress_network   = { network = "public", subnet = "public-subnet" }
  network_mtu      = 1362
  domains          = ["site-a.example.org"]
  edge_sources     = ["198.51.100.5/32"]
  admin            = { users = { ops = ["ssh-ed25519 AAAA ops@example.org"] }, ssh_cidrs = [] }
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

  # Demonstration mode, without certificates: the stack warns (ADR-0008).
  expect_failures = [check.certificates]

  variables {
    zones          = ["az-1"]
    instance_count = 2
  }

  assert {
    condition     = alltrue([for i in values(module.web.instances) : i.az == "az-1"])
    error_message = "With one zone, every instance must be in it."
  }
}

run "three_zones" {
  command = plan

  expect_failures = [check.certificates]

  variables {
    zones          = ["az-1", "az-2", "az-3"]
    instance_count = 4
    volume_zones   = { az-2 = "volumes-2" }
  }

  assert {
    condition     = [for n in ["site-a-web-1", "site-a-web-2", "site-a-web-3", "site-a-web-4"] : module.web.instances[n].az] == ["az-1", "az-2", "az-3", "az-1"]
    error_message = "The instances must be spread over the zones in order."
  }

  assert {
    condition     = local.boot_in["az-2"].az == "volumes-2" && local.boot_in["az-1"].az == null
    error_message = "A root volume must take the storage zone mapped to its instance's zone, or the cloud's default."
  }
}
