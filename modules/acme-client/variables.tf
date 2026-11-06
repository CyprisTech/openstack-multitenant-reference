variable "certificates" {
  description = <<-EOT
    Where the certificate comes from (ADR-0008): any ACME directory (Let's Encrypt, or the
    organisation's authority), through the DNS-01 challenge. null: no ACME client.
    - directory_url: the ACME directory, for example
      "https://acme-v02.api.letsencrypt.org/directory".
    - ca_bundle: root certificate (PEM) of an authority that is not publicly trusted.
    - email: contact of the ACME account.
    - dns.provider: a lego DNS provider code, for example "rfc2136".
    - dns.settings: for rfc2136, nameserver ("host:port"), tsig_key_name, tsig_algorithm and
      tsig_secret; for any other provider, its lego environment variables, as documented by lego.
    - dns.resolvers: name servers ("host:port") lego checks the TXT record on, and only on;
      empty uses the instance's resolvers and the zone's authoritative servers.
    The settings reach the instance through its user data, readable by the members of the
    project: give a key restricted to the _acme-challenge records of these domains.
  EOT
  type = object({
    directory_url = string
    ca_bundle     = optional(string)
    email         = string
    dns = object({
      provider  = string
      settings  = map(string)
      resolvers = optional(list(string), [])
    })
  })
  default   = null
  sensitive = true
}

variable "domains" {
  description = "Names the certificate is for."
  type        = list(string)
}

variable "certificate_path" {
  description = "Where the deploy hook installs the certificate (PEM, with its chain)."
  type        = string
}

variable "key_path" {
  description = "Where the deploy hook installs the private key (PEM, mode 0600)."
  type        = string
}

variable "deploy_commands" {
  description = "Commands the deploy hook runs once the certificate and key are installed, for example to reload the service."
  type        = list(string)
  default     = []
}

variable "lego_version" {
  description = "Version of lego installed on the instance (release archive from GitHub), pinned."
  type        = string
  default     = "5.6.0"
}
