# Internal demonstration service for the isolation test (ADR-0002, D7): a small instance, a
# shared service of the internal services plane, answering on port 8080. Only the sources given in
# allowed_sources are admitted: the Kubernetes tenant's address on that plane (its router's
# gateway address on a plane with NAT, its range on a plane without NAT). On an operator
# plane the service has a floating IP of the plane, which also carries SSH for the
# administration sources (the test cloud uses that plane as administration network).

locals {
  name = "${var.site}-internal-service"
}

module "planes" {
  source = "../../../modules/plane-attachment"

  planes          = ["internal"]
  attachment      = var.plane_attachment
  default_gateway = "internal"
  instances       = [local.name]
  exposure        = { primary = "internal" }
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    service = { ports = [8080], sources = var.allowed_sources }
    ssh     = { ports = [22], sources = var.ssh_cidrs }
  }
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.5"

  hostname       = local.name
  package_update = false
  users          = { debug = { ssh_authorized_keys = var.ssh_keys, sudo = true } }
  write_files = {
    "/srv/www/index.html" = { content = "internal-service\n" }
    "/etc/systemd/system/internal-service.service" = {
      content = file("${path.module}/files/internal-service.service")
    }
  }
  runcmd = ["systemctl daemon-reload", "systemctl enable --now internal-service.service"]
}

module "service" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.5"

  tenant = {
    existing = {
      networks = module.planes.networks
    }
    networks = {
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.cidr } }
        routers = module.planes.routers
      }
    }
    security_groups = {
      (local.name) = {
        rules = module.admission.rules
      }
    }
    instances = {
      (local.name) = {
        az        = var.az, flavor = var.flavor, image = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit.rendered
        ports = {
          main = {
            network     = local.name, subnet = "main", security_groups = [local.name]
            floating_ip = module.planes.ports[local.name].floating_ip
          }
        }
      }
    }
  }
}

