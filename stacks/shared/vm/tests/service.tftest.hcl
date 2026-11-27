# The shared service on virtual machines (spec docs/specs/shared-vm.md), with a mocked provider:
# no cloud is needed.

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
  mock_data "openstack_networking_router_v2" {
    defaults = { external_fixed_ip = [{ ip_address = "198.51.100.40", subnet_id = "00000000-0000-0000-0000-000000000032" }] }
  }
}

variables {
  cloud            = "example"
  site             = "site-a"
  zones            = ["az-1"]
  image            = "ubuntu-24.04"
  flavor           = "m1.small"
  boot_volume_size = 8
  egress           = "router"
  egress_network   = { network = "public", subnet = "public-subnet" }
  admin            = { users = { ops = ["ssh-ed25519 AAAA ops@example.org"] }, ssh_cidrs = [] }
  plane_attachment = {
    internal = {
      mode         = "gateway"
      nat          = false
      cidr         = "203.0.113.0/24"
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

run "closed_before_its_consumers" {
  command = plan

  assert {
    condition     = jsonencode(keys(module.service.instances)) == jsonencode(["site-a-service-1", "site-a-service-2"])
    error_message = "Two instances by default."
  }

  # Behind a load balancer, the listener admits only the service's own network without consumers:
  # Octavia admits every source when allowed_cidrs is empty.
  assert {
    condition     = jsonencode(keys(module.service.load_balancers)) == jsonencode(["site-a-service-demo"])
    error_message = "One load balancer per service when there are several instances."
  }

  assert {
    condition     = length(local.sources.demo) == 0 && jsonencode(local.instance_sources.demo) == jsonencode([var.cidr])
    error_message = "No consumer: only the amphorae, on the service's network, reach the instances."
  }

  assert {
    condition     = local.demo && contains(keys(local.workload.write_files["site-a-service-1"]), "/usr/local/bin/demo-service")
    error_message = "Without a workload, the demonstration runs."
  }

  assert {
    condition     = !local.selfsigned && !local.acme
    error_message = "Without names, the demonstration answers in HTTP, without a certificate."
  }
}

run "consumers_admitted_on_the_ports_only" {
  command = plan

  variables {
    consumers = ["198.51.100.7/32"]
    services = {
      registry = { ports = [443, 5000], domains = ["registry.example.org"] }
      ldap     = { ports = [636], sources = ["198.51.100.8/32"] }
    }
    workload = { packages = ["slapd"], runcmd = ["systemctl enable --now slapd"] }
  }

  # Demonstration certificates: the stack warns (ADR-0008).
  expect_failures = [check.certificates]

  assert {
    condition     = jsonencode(local.sources) == jsonencode({ ldap = ["198.51.100.8/32"], registry = ["198.51.100.7/32"] })
    error_message = "A service admits its sources, the consumers by default."
  }

  # Behind the load balancers, the instances admit the amphorae, on the service's network.
  assert {
    condition     = jsonencode(local.instance_sources) == jsonencode({ ldap = [var.cidr], registry = [var.cidr] })
    error_message = "Behind load balancers, the instances admit the service's network only."
  }

  assert {
    condition     = jsonencode(keys(module.service.load_balancers)) == jsonencode(["site-a-service-ldap", "site-a-service-registry"])
    error_message = "One load balancer, so one address, per service."
  }

  assert {
    condition     = !local.demo && strcontains(module.cloudinit["site-a-service-1"].rendered, "slapd")
    error_message = "The workload reaches the cloud-init of the instances."
  }

  assert {
    condition     = local.selfsigned && jsonencode(local.domains) == jsonencode(["registry.example.org"])
    error_message = "Names without certificates: a self-signed certificate for them."
  }
}

run "one_instance_is_the_address" {
  command = plan

  variables {
    instance_count = 1
    consumers      = ["198.51.100.7/32"]
  }

  assert {
    condition     = length(module.service.load_balancers) == 0
    error_message = "One instance: no load balancer."
  }

  assert {
    condition     = jsonencode(local.instance_sources.demo) == jsonencode(["198.51.100.7/32"])
    error_message = "One instance admits the consumers itself."
  }
}

run "spread_over_the_zones" {
  command = plan

  variables {
    zones          = ["az-1", "az-2", "az-3"]
    instance_count = 3
    volume_zones   = { az-2 = "volumes-2" }
  }

  assert {
    condition     = jsonencode([for n in sort(keys(local.zone_of)) : local.zone_of[n]]) == jsonencode(["az-1", "az-2", "az-3"])
    error_message = "The instances are spread over the zones in order."
  }

  assert {
    condition     = local.boot_in["az-2"].az == "volumes-2" && local.boot_in["az-1"].az == null
    error_message = "A root volume takes the storage zone mapped to its instance's zone."
  }
}

run "names_in_the_internal_zone" {
  command = plan

  variables {
    services      = { registry = { ports = [443], domains = ["registry.int.example.org"] } }
    internal_zone = { name = "int.example.org." }
    dns           = "output"
    certificates = {
      directory_url = "https://acme.example.org/directory"
      email         = "ops@example.org"
      dns           = { provider = "rfc2136", settings = { nameserver = "192.0.2.53:53", tsig_key_name = "acme", tsig_algorithm = "hmac-sha256", tsig_secret = "c2VjcmV0" } }
    }
  }

  assert {
    condition     = length(module.names) == 0 && jsonencode(keys(local.records)) == jsonencode(["registry.int.example.org"])
    error_message = "dns = \"output\": the records are given, not written."
  }

  assert {
    condition     = local.records["registry.int.example.org"].name == "registry"
    error_message = "The record is named relative to the zone."
  }

  assert {
    condition     = local.acme && !local.selfsigned && contains(local.reload, "systemctl restart demo-service.service")
    error_message = "With certificates, the deploy hook starts the demonstration."
  }
}

run "a_shared_service_joins_the_internal_services_plane" {
  command = plan

  variables {
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

  expect_failures = [var.plane_attachment]
}

run "the_same_port_twice" {
  command = plan

  variables {
    services = { a = { ports = [443] }, b = { ports = [443] } }
  }

  expect_failures = [var.services]
}

run "no_egress_needs_a_workload" {
  command = plan

  variables {
    egress         = "none"
    egress_network = null
  }

  expect_failures = [var.egress]
}

run "no_agent_without_the_observability_plane" {
  command = plan

  variables {
    monitoring = { receiver = "http://198.51.100.10:9090" }
    plane_attachment = {
      internal = {
        mode         = "gateway"
        nat          = false
        cidr         = "203.0.113.0/24"
        network_id   = "00000000-0000-0000-0000-000000000001"
        network_name = "internal"
        subnet_id    = "00000000-0000-0000-0000-000000000002"
      }
    }
  }

  assert {
    condition     = length(module.metrics) == 0
    error_message = "Without the observability plane, the receiver is out of reach: no agent."
  }
}

run "the_agent_with_the_observability_plane" {
  command = plan

  variables {
    monitoring = { receiver = "http://198.51.100.10:9090" }
  }

  assert {
    condition     = length(module.metrics) == 2
    error_message = "With the observability plane, each instance runs the agent."
  }
}
