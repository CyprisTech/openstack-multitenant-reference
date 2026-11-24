# Records of the internal names (ADR-0016, D2), in Designate or as an output, with a mocked
# provider: no cloud is needed.

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
  zones         = ["az-1"]
  internal_zone = { id = "00000000-0000-0000-0000-000000000050", name = "example.org." }
}

run "designate" {
  command = apply

  assert {
    condition     = length(module.names) == 1
    error_message = "With dns = \"designate\", the records are written in the zone."
  }

  assert {
    condition     = join(",", keys(output.dns_records)) == "services.example.org A"
    error_message = "dns_records gives the records in both modes, keyed \"<name> <type>\"."
  }

  assert {
    condition     = output.dns_records["services.example.org A"].name == "services" && output.dns_records["services.example.org A"].zone == "example.org."
    error_message = "The name is relative to its zone."
  }
}

run "output_without_zone_id" {
  command = apply

  variables {
    dns           = "output"
    internal_zone = { name = "example.org." }
  }

  assert {
    condition     = length(module.names) == 0
    error_message = "With dns = \"output\", no record is written in Designate."
  }

  assert {
    condition     = length(output.dns_records["services.example.org A"].records) == 1
    error_message = "The record of each name, with the address of the internal ingress."
  }
}
