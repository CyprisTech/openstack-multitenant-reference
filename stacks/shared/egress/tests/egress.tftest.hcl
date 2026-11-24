# The shared egress (ADR-0016, D1), with a mocked provider: no cloud is needed. The runs use
# routed planes: on a plane with NAT, the floating IP takes the plane's name, which a mocked provider
# does not give for a network adopted by ID (that path is the vm stack's, checked by the campaigns).

mock_provider "openstack" {
  mock_resource "openstack_networking_port_v2" {
    defaults = { all_fixed_ips = ["10.39.0.10"] }
  }
  mock_resource "openstack_networking_floatingip_v2" {
    defaults = { address = "203.0.113.39" }
  }
  mock_resource "openstack_lb_loadbalancer_v2" {
    defaults = { vip_address = "10.39.0.20", vip_port_id = "00000000-0000-0000-0000-000000000020" }
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
  zones          = ["az-1", "az-2"]
  image          = "ubuntu-24.04"
  flavor         = "m1.small"
  egress_network = { network = "public", subnet = "public-subnet" }
  network_mtu    = 1362
  admin          = { users = { ops = ["ssh-ed25519 AAAA ops@example.org"] }, ssh_cidrs = ["192.0.2.0/24"] }
  tenants = {
    builds = { sources = ["203.0.113.21/32"], domains = [".ubuntu.com", "pypi.org"] }
    ci-1   = { sources = ["10.23.0.0/24"], domains = [".github.com"] }
  }
  plane_attachment = {
    internal = {
      mode         = "interface"
      nat          = false
      cidr         = "172.31.2.0/24"
      network_id   = "00000000-0000-0000-0000-000000000001"
      network_name = "internal"
      subnet_id    = "00000000-0000-0000-0000-000000000002"
    }
    observability = {
      mode         = "interface"
      nat          = false
      cidr         = "172.31.1.0/24"
      network_id   = "00000000-0000-0000-0000-000000000003"
      network_name = "observability"
      subnet_id    = "00000000-0000-0000-0000-000000000004"
    }
  }
}

run "two_proxies_behind_the_load_balancer" {
  command = apply

  assert {
    condition     = length(module.egress.instances) == 2 && module.egress.instances["site-a-egress-2"].az == "az-2"
    error_message = "Two proxy instances, spread over the zones."
  }

  assert {
    condition     = output.proxy == "http://10.39.0.20:3128"
    error_message = "On a routed plane, the proxy is the load balancer's own address."
  }

  assert {
    condition     = join(",", local.sources) == "203.0.113.21/32,10.23.0.0/24"
    error_message = "The load balancer admits the sources of every declared tenant."
  }

  assert {
    condition     = local.tenant_metadata["tenants"] == "2" && jsondecode(local.tenant_metadata["tenant-ci-1-0"]).d == [".github.com"]
    error_message = "One metadata item per tenant here, with its sources and names; the item tenants counts them."
  }

  assert {
    condition     = strcontains(local.squid, "http_port 3128 require-proxy-header") && strcontains(local.squid, "acl load_balancer src 10.39.0.0/27")
    error_message = "The proxy reads the PROXY header of the load balancer only."
  }

  assert {
    condition     = strcontains(local.squid, "include /etc/squid/tenants.conf\n\nhttp_access deny all")
    error_message = "The tenants' rules, then everything else refused."
  }
}

run "long_names_split_in_items" {
  command = apply

  variables {
    tenants = {
      builds = { sources = ["203.0.113.21/32"], domains = [for i in range(30) : ".mirror-${i}.example.org"] }
    }
  }

  assert {
    condition     = local.tenant_metadata["tenants"] == tostring(length(local.tenant_items)) && length(local.tenant_items) > 1
    error_message = "A tenant longer than 255 characters takes several items."
  }

  assert {
    condition     = alltrue([for v in values(local.tenant_items) : length(v) <= 255]) && jsondecode(join("", [for i in range(length(local.tenant_items)) : local.tenant_items["tenant-builds-${i}"]])).s == ["203.0.113.21/32"]
    error_message = "Each item fits a metadata value, and the items joined in order give the tenant back."
  }
}

run "no_tenant" {
  command = apply

  variables {
    instance_count = 1
    tenants        = {}
  }

  assert {
    condition     = local.tenant_metadata == { tenants = "0" } && length(local.sources) == 0
    error_message = "Without tenants, every request is refused."
  }
}
