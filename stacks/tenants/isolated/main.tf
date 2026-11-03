# Tenant "isolated": a workload with no public exposure and no path to the other tenants
# (ADR-0003, D3). Its network has a single router, to the monitoring plane: the workload pushes
# its metrics to the receiver through it (ADR-0007), and reaches nothing else.
#
# The workload is a stand-in with no package and no Internet access: it pushes one metric in
# OTLP (JSON over HTTP, Python standard library), which the receiver accepts as well as remote
# write.

locals {
  prefix   = "${var.site}-isolated"
  instance = "${local.prefix}-1"

  bastion_name = "${local.prefix}-bastion"

  pusher = <<-EOT
    #!/usr/bin/env python3
    # Pushes isolated_up = 1 every 30 seconds to the receiver (OTLP, JSON over HTTP).
    import json, sys, time, urllib.request

    URL = sys.argv[1].rstrip("/") + "/api/v1/otlp/v1/metrics"
    ATTRIBUTES = {"service.name": "isolated", "service.instance.id": "${local.instance}",
                  "site": "${var.site}", "tenant": "isolated"}

    while True:
        body = {"resourceMetrics": [{
            "resource": {"attributes": [{"key": k, "value": {"stringValue": v}} for k, v in ATTRIBUTES.items()]},
            "scopeMetrics": [{"metrics": [{"name": "isolated_up", "gauge": {
                "dataPoints": [{"asDouble": 1, "timeUnixNano": str(time.time_ns())}]}}]}],
        }]}
        request = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(request, timeout=10).read()
        except Exception as e:
            print(f"push failed: {e}", file=sys.stderr, flush=True)
        time.sleep(30)
  EOT

  pusher_unit = <<-EOT
    [Unit]
    Description=Stand-in workload: pushes its metric to the receiver
    After=network-online.target

    [Service]
    ExecStart=/usr/bin/python3 /usr/local/bin/push-metrics ${coalesce(var.monitoring.receiver, "none")}
    Restart=always
    DynamicUser=yes

    [Install]
    WantedBy=multi-user.target
  EOT
}

# How the stack joins the monitoring plane (ADR-0004). Its router is the default gateway:
# the tenant has no other way out.
module "planes" {
  source = "../../../modules/plane-attachment"

  planes          = ["monitoring"]
  attachment      = var.plane_attachment
  default_gateway = "monitoring"
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    ssh = { ports = [22], sources = var.admin.ssh_cidrs }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = local.bastion_name
  bastion       = var.bastion
  admin_network = "${local.prefix}-admin"
  default_cidr  = "10.33.0.0/28"
  network       = local.prefix
  port          = "isolated"
  users         = var.admin.users
  instance = {
    az     = var.az
    image  = var.image
    flavor = var.flavor
    boot   = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.4"

  hostname       = local.instance
  package_update = false # no Internet access by design
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }

  write_files = var.monitoring.receiver == null ? {} : {
    "/usr/local/bin/push-metrics"              = { content = local.pusher, permissions = "0755" }
    "/etc/systemd/system/push-metrics.service" = { content = local.pusher_unit }
  }
  runcmd = var.monitoring.receiver == null ? [] : [
    "systemctl daemon-reload",
    "systemctl enable --now push-metrics.service",
  ]
}

module "isolated" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.4"

  tenant = {
    existing = {
      networks = merge(module.planes.networks, module.bastion.existing_networks)
    }

    networks = merge({
      (local.prefix) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.isolated_cidr, dns_nameservers = var.dns_nameservers } }
        # The only router, to the monitoring plane, also the default gateway.
        routers = module.planes.routers
      }
    }, module.bastion.networks)

    security_groups = merge({
      "${local.prefix}-workload" = {
        description = "Isolated workload: SSH from the bastion only"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)

    instances = merge({
      (local.instance) = {
        az        = var.az
        flavor    = var.flavor
        image     = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit.rendered
        labels    = ["isolated"]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-workload"]
          }
        }
      }
    }, module.bastion.instances)
  }
}
