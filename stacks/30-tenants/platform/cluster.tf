# Cluster definition and bootstrap instance (ADR-0002, D2 and D3). Every version is pinned here.

locals {
  versions = {
    kind          = "v0.33.0"
    kubectl       = "v1.36.5"
    cluster_api   = "v1.14.3"
    capo          = "v0.15.1"
    caaph         = "v0.6.4"
    orc           = "v2.6.0"
    cilium        = "1.20.4"
    occm          = "2.36.5"
    cinder_csi    = "2.36.5"
    traefik_chart = "42.1.3"
    prometheus    = "29.39.0"
    gateway_api   = "v1.6.3"
    metrics       = "3.14.0" # metrics-server chart
    csr_approver  = "1.2.15" # kubelet-csr-approver chart
  }

  # Pod network MTU: cluster network MTU minus the VXLAN overhead (ADR-0002, D4).
  pod_mtu = var.network_mtu == null ? 0 : var.network_mtu - 50

  # Cluster API templates are immutable: their names carry a revision derived from their
  # content, so that a change creates new templates and Cluster API rolls the machines.
  revision = substr(sha256(join("/", [
    file("${path.module}/manifests/cluster-class.yaml.tftpl"),
    jsonencode([var.cluster, var.az, local.network, local.subnet, local.router, local.admin_network.network, var.admin.ssh_key_name]),
  ])), 0, 8)

  manifest_vars = {
    revision      = local.revision
    cluster       = var.cluster
    prefix        = local.prefix
    az            = var.az
    network       = local.network
    subnet        = local.subnet
    router        = local.router
    admin_network = local.admin_network.network
    admin_sources = var.admin.sources
    ssh_key_name  = var.admin.ssh_key_name
    pod_mtu       = local.pod_mtu
    versions      = local.versions
    svc_public    = var.planes.svc_public.network
    monitoring    = var.planes.monitoring.network
    edge_sources  = local.edge_sources
    collectors    = var.monitoring.collector_cidrs
    cluster_cidr  = var.cluster_cidr
    svc_public_id = data.openstack_networking_network_v2.svc_public.id
    monitoring_id = data.openstack_networking_network_v2.monitoring.id
  }

  manifests = {
    "cluster-class.yaml" = templatefile("${path.module}/manifests/cluster-class.yaml.tftpl", local.manifest_vars)
    "cluster.yaml"       = templatefile("${path.module}/manifests/cluster.yaml.tftpl", local.manifest_vars)
    "addons.yaml"        = templatefile("${path.module}/manifests/addons.yaml.tftpl", local.manifest_vars)
  }

  scripts = {
    "create-cluster.sh" = templatefile("${path.module}/scripts/create-cluster.sh.tftpl", local.manifest_vars)
    "delete-cluster.sh" = templatefile("${path.module}/scripts/delete-cluster.sh.tftpl", local.manifest_vars)
  }
}

# Load balancers of the cluster Services take their floating IP from these planes (by ID).
data "openstack_networking_network_v2" "svc_public" {
  name = var.planes.svc_public.network
}

data "openstack_networking_network_v2" "monitoring" {
  name = var.planes.monitoring.network
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.2"
  count  = var.bootstrap ? 1 : 0

  hostname = local.instance
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = ["docker.io", "jq"]

  write_files = merge(
    # kind takes the MTU of the default Docker bridge: it must not exceed the MTU of the cluster
    # network, or large replies of the cloud APIs are dropped silently (no "fragmentation needed").
    var.network_mtu == null ? {} : { "/etc/docker/daemon.json" = { content = jsonencode({ mtu = var.network_mtu }) } },
    { for name, content in local.manifests : "/opt/platform/manifests/${name}" => { content = content } },
    { for name, content in local.scripts : "/opt/platform/${name}" => { content = content, permissions = "0755" } },
  )

  runcmd = [
    "curl -fsSLo /usr/local/bin/kind https://github.com/kubernetes-sigs/kind/releases/download/${local.versions.kind}/kind-linux-amd64",
    "curl -fsSLo /usr/local/bin/kubectl https://dl.k8s.io/release/${local.versions.kubectl}/bin/linux/amd64/kubectl",
    "curl -fsSLo /usr/local/bin/clusterctl https://github.com/kubernetes-sigs/cluster-api/releases/download/${local.versions.cluster_api}/clusterctl-linux-amd64",
    "chmod 0755 /usr/local/bin/kind /usr/local/bin/kubectl /usr/local/bin/clusterctl",
  ]
}
