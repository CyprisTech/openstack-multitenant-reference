# Boot check of the Kubernetes node image (images/kubernetes-node): one instance from the
# image, on the build network, with a floating IP on the administration network. The check
# itself is manual (see README.md): kubelet, kubeadm and containerd versions, and the source
# address of the operator connection.

variable "site" {
  type = string
}

variable "az" {
  type = string
}

variable "flavor" {
  type = string
}

variable "image" {
  description = "Name of the node image built by images/kubernetes-node."
  type        = string
}

variable "admin_network" {
  type = object({ network = string, subnet = string })
}

variable "ssh_public_key" {
  type = string
}

variable "cloud" {
  type = string
}

locals {
  prefix = "${var.site}-node-image"
}

module "check" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.2"

  tenant = {
    existing = {
      networks = {
        build = { name = local.prefix, subnets = { main = { name = "${local.prefix}-main" } } }
        admin = { name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } } }
      }
      security_groups = { build = { name = local.prefix } }
    }

    instances = {
      "${local.prefix}-check" = {
        az     = var.az
        flavor = var.flavor
        image  = var.image
        boot   = { source = "volume", size = 20 }
        # image-builder images ship cloud-init: the key goes to the default user.
        user_data = "#cloud-config\nssh_authorized_keys:\n  - ${var.ssh_public_key}\n"
        ports = {
          main = { network = "build", subnet = "main", security_groups = ["build"], floating_ip = { pool = "admin" } }
        }
      }
    }
  }
}

output "floating_ip" {
  value = module.check.instances["${local.prefix}-check"].ports.main.floating_ip
}
