terraform {
  required_version = ">= 1.9"
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = "~> 3.2" }
    random    = { source = "hashicorp/random", version = "~> 3.6" }
    tls       = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "openstack" {
  cloud = var.cloud
}
