# Exposure and egress declared (ADR-0016, D1), with a mocked provider: no cloud is needed.

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

run "private_tenant" {
  command = plan

  variables {
    name           = "private"
    zones          = ["az-1"]
    exposure       = "none"
    egress         = "none"
    egress_network = null
    edge_sources   = []
    instance_count = 1
    monitoring     = { receiver = "http://198.51.100.10:9090" }
  }

  assert {
    condition     = keys(module.planes.routers) == ["observability", "transit"]
    error_message = "A private tenant joins the observability plane only, through its transit router: no publication router, no egress router."
  }

  assert {
    condition     = length([for r in module.planes.routers.transit.routes : r if r.destination == "0.0.0.0/0"]) == 0
    error_message = "Without egress, the transit router has no default route."
  }

  assert {
    condition     = length(output.published_domains) == 0 && output.service_address == null
    error_message = "A private tenant publishes nothing and has no service address."
  }

  assert {
    condition     = keys(module.web.instances) == ["site-a-private-1"]
    error_message = "The name of the tenant names its resources."
  }
}

run "private_tenant_runs_the_standin_workload" {
  command = plan

  variables {
    name           = "private"
    zones          = ["az-1"]
    exposure       = "none"
    egress         = "none"
    egress_network = null
    instance_count = 1
    monitoring     = { receiver = "http://198.51.100.10:9090" }
  }

  assert {
    condition     = length(module.metrics) == 0 && contains(keys(local.standin_files["site-a-private-1"]), "/usr/local/bin/push-metrics")
    error_message = "Without egress, no package: the stand-in workload pushes the metric."
  }
}

run "no_egress_serves_nothing" {
  command = plan

  variables {
    zones          = ["az-1"]
    egress         = "none"
    egress_network = null
    exposure       = "entry-point"
  }

  expect_failures = [var.egress, check.certificates]
}

run "public_needs_the_egress" {
  command = plan

  variables {
    zones          = ["az-1"]
    egress         = "none"
    egress_network = null
    exposure       = "public"
  }

  expect_failures = [var.egress, check.certificates]
}

run "exposed_tenant_unchanged" {
  command = plan

  expect_failures = [check.certificates]

  variables {
    zones          = ["az-1"]
    instance_count = 2
  }

  assert {
    condition     = contains(keys(module.planes.routers), "publication") && length([for r in module.planes.routers.transit.routes : r if r.destination == "0.0.0.0/0" && r.next_hop_router == "egress"]) == 1
    error_message = "By default the tenant is published through the entry point and goes out through its egress router."
  }
}
