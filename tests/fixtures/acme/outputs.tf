output "certificates" {
  description = "The certificates input of each tenant stack, keyed by tenant: ACME directory, root, DNS-01 through RFC 2136 with the tenant's TSIG key."
  sensitive   = true
  value = {
    for t in keys(var.tenants) : t => {
      directory_url = "https://${local.address}/acme/acme/directory"
      ca_bundle     = tls_self_signed_cert.root.cert_pem
      email         = "admin@${local.zone}"
      dns = {
        provider = "rfc2136"
        settings = {
          nameserver     = "${local.address}:53"
          tsig_key_name  = t
          tsig_algorithm = "hmac-sha256"
          tsig_secret    = random_bytes.tsig[t].base64
        }
        # The test zone is not in the public DNS: lego checks the TXT record on Knot directly.
        resolvers = ["${local.address}:53"]
      }
    }
  }
}

output "root_certificate" {
  description = "Root certificate of the test authority, for the clients of the tests."
  value       = tls_self_signed_cert.root.cert_pem
}

output "address" {
  description = "Address of the authority on the internal services plane (DNS on 53, ACME on 443)."
  value       = local.address
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network."
  value       = module.authority.instances["${local.name}-bastion"].ports["admin"].floating_ip
}

output "zone" {
  description = "The test zone."
  value       = local.zone
}

output "tenants" {
  description = "Names each tenant may obtain certificates for."
  value       = var.tenants
}

output "instance_address" {
  description = "Address of the authority on its own network, reached through the bastion (SSH)."
  value       = module.authority.instances[local.name].ports["main"].ip
}
