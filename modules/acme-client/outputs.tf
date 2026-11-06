output "write_files" {
  description = "Files to write, in the shape of the write_files input of the cloudinit module."
  sensitive   = true
  value = local.enabled ? merge({
    "/etc/lego/dns.env" = {
      content     = join("", [for k, v in local.dns_env : "${k}='${replace(v, "'", "'\\''")}'\n"])
      permissions = "0600"
    }
    # Obtains the certificate, or renews it when it is due, and installs it.
    "/usr/local/sbin/lego-certificate" = {
      content     = templatefile("${path.module}/files/lego-certificate.sh.tftpl", { flags = local.flags })
      permissions = "0755"
    }
    "/usr/local/sbin/lego-deploy" = {
      content = templatefile("${path.module}/files/lego-deploy.sh.tftpl", {
        certificate_path = var.certificate_path
        key_path         = var.key_path
        commands         = var.deploy_commands
      })
      permissions = "0755"
    }
    "/etc/systemd/system/lego-certificate.service" = { content = file("${path.module}/files/lego-certificate.service") }
    "/etc/systemd/system/lego-certificate.timer"   = { content = file("${path.module}/files/lego-certificate.timer") }
    }, var.certificates.ca_bundle == null ? {} : {
    "/etc/lego/ca.pem" = { content = var.certificates.ca_bundle }
  }) : {}
}

output "runcmd" {
  description = "Commands that install lego and start its timer, once the service it serves is installed."
  value = local.enabled ? [
    "curl -fsSL https://github.com/go-acme/lego/releases/download/v${var.lego_version}/lego_v${var.lego_version}_linux_amd64.tar.gz | tar -xz -C /usr/local/bin lego",
    "systemctl daemon-reload",
    "systemctl enable --now lego-certificate.timer",
    "systemctl start --no-block lego-certificate.service",
  ] : []
}
