terraform {
  required_version = ">= 1.9"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.2"
    }
  }
}

# Credentials come from clouds.yaml. One entry per stack and per site (ADR-0001, D1 and D9).
provider "openstack" {
  cloud = var.cloud
}
