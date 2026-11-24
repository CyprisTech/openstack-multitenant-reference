# Records of the public names (ADR-0016, D2), in Designate or as an output, with a mocked
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
  mock_data "openstack_dns_zone_v2" {
    defaults = { id = "00000000-0000-0000-0000-000000000040" }
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
  zones      = ["az-1"]
  public_dns = { zone = "example.org.", names = ["", "www"] }
}

run "designate" {
  command = apply

  assert {
    condition     = length(module.edge.load_balancers[local.prefix].fqdns) == 2
    error_message = "With dns = \"designate\", the records are written in the zone."
  }

  assert {
    condition     = join(",", keys(output.dns_records)) == "example.org A,www.example.org A"
    error_message = "dns_records gives the records in both modes, keyed \"<name> <type>\"."
  }

  assert {
    condition     = output.dns_records["www.example.org A"].records == ["203.0.113.10"] && output.dns_records["www.example.org A"].ttl == 300
    error_message = "A record of the public floating IP, with the TTL of public_dns."
  }
}

run "output" {
  command = apply

  variables {
    dns = "output"
  }

  assert {
    condition     = length(module.edge.load_balancers[local.prefix].fqdns) == 0
    error_message = "With dns = \"output\", no record is written in Designate."
  }

  assert {
    condition     = output.dns_records["example.org A"].name == "" && output.dns_records["example.org A"].zone == "example.org."
    error_message = "The apex keeps its relative name, empty, with its zone."
  }
}
