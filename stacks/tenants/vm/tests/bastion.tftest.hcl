# Placement of the bastion (ADR-0014, D2), with a mocked provider: no cloud is needed.

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

run "bastion_own_network" {
  command = plan

  expect_failures = [check.certificates]

  variables {
    zones   = ["az-1"]
    bastion = { external_network = { network = "intranet", subnet = "intranet-subnet" }, ssh_cidrs = ["203.0.113.50/32"] }
  }

  assert {
    condition     = length(module.bastion.networks) == 1 && module.bastion.floating_ip_port == "admin"
    error_message = "By default, the bastion has its own network and its floating IP on its own port."
  }

  assert {
    condition     = keys(module.bastion.instances["site-a-web-bastion"].ports) == ["admin", "web"]
    error_message = "On its own network, the bastion has a second port on the stack's network."
  }
}

run "bastion_on_stack_network" {
  command = plan

  expect_failures = [check.certificates]

  variables {
    zones             = ["az-1"]
    bastion           = { external_network = { network = "public", subnet = "public-subnet" }, ssh_cidrs = ["203.0.113.50/32"] }
    bastion_placement = "stack-network"
  }

  assert {
    condition     = length(module.bastion.networks) == 0 && length(module.bastion.existing_networks) == 0
    error_message = "On the stack's network, the bastion has no network or router of its own."
  }

  assert {
    condition     = keys(module.bastion.instances["site-a-web-bastion"].ports) == ["web"] && module.bastion.instances["site-a-web-bastion"].ports["web"].floating_ip.pool == "egress"
    error_message = "On the stack's network, the bastion has one port, its floating IP on the egress router."
  }
}

run "bastion_on_stack_network_needs_the_egress_network" {
  command = plan

  variables {
    zones             = ["az-1"]
    bastion           = { external_network = { network = "intranet", subnet = "intranet-subnet" }, ssh_cidrs = ["203.0.113.50/32"] }
    bastion_placement = "stack-network"
  }

  expect_failures = [var.bastion_placement, check.certificates]
}

run "egress_network_without_subnet" {
  command = plan

  expect_failures = [check.certificates]

  variables {
    zones             = ["az-1"]
    egress_network    = { network = "public" }
    bastion           = { external_network = { network = "public" }, ssh_cidrs = ["203.0.113.50/32"] }
    bastion_placement = "stack-network"
  }

  assert {
    condition     = keys(module.bastion.instances["site-a-web-bastion"].ports) == ["web"]
    error_message = "Without a subnet name, the external network is used as it is (a public network with several subnets)."
  }
}
