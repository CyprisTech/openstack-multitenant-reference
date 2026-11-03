output "packages" {
  description = "Packages to install: the node exporter, and Prometheus when an agent pushes."
  value       = concat(["prometheus-node-exporter"], local.enabled ? ["prometheus"] : [])
}

output "write_files" {
  description = "Files to write, in the shape of the write_files input of the cloudinit module."
  value = local.enabled ? {
    "/etc/prometheus/agent.yml"                           = { content = local.config }
    "/etc/systemd/system/prometheus.service.d/agent.conf" = { content = local.drop_in }
  } : {}
}

output "runcmd" {
  description = "Commands that start the agent once its package is installed."
  value       = local.enabled ? ["systemctl daemon-reload", "systemctl restart prometheus"] : []
}
