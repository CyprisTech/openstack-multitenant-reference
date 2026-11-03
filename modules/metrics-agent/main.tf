# The metrics agent of an instance (ADR-0007, D2): Prometheus in agent mode reads the local
# exporters and pushes to the receiver of the shared services (remote write). Nothing connects
# into the instance for its metrics. No resource: the outputs are fragments of the cloud-init
# configuration of the instance.
#
# The agent runs from the distribution's prometheus package, started by a systemd drop-in rather
# than through its configuration files, which the package owns.

locals {
  enabled = var.receiver != null

  config = yamlencode({
    global = {
      scrape_interval = var.scrape_interval
      external_labels = var.labels
    }
    scrape_configs = [
      for job, targets in var.targets : {
        job_name       = job
        static_configs = [{ targets = targets }]
      }
    ]
    remote_write = [{ url = "${trimsuffix(var.receiver == null ? "" : var.receiver, "/")}/api/v1/write" }]
  })

  drop_in = <<-EOT
    [Service]
    ExecStart=
    ExecStart=/usr/bin/prometheus --enable-feature=agent --config.file=/etc/prometheus/agent.yml --storage.agent.path=/var/lib/prometheus/agent
  EOT
}
