# Up to v0.3, the cluster was declared in this stack; it lives in modules/kubernetes-cluster since.
moved {
  from = module.planes
  to   = module.cluster.module.planes
}

moved {
  from = module.admission
  to   = module.cluster.module.admission
}

moved {
  from = terraform_data.checks
  to   = module.cluster.terraform_data.checks
}

moved {
  from = openstack_networking_floatingip_v2.ingress[0]
  to   = module.cluster.openstack_networking_floatingip_v2.entry["public"]
}

# Up to v0.3 state: chained with the moved block of the module (module.platform to module.tenant).
# Targeting module.cluster.module.tenant directly is rejected at plan: "Ambiguous move statements".
moved {
  from = module.platform
  to   = module.cluster.module.platform
}

moved {
  from = module.cloudinit
  to   = module.cluster.module.cloudinit
}
