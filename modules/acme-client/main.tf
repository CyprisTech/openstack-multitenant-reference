# The ACME client of an instance (ADR-0008, D3): lego obtains the certificate of the domains
# through the DNS-01 challenge, renews it from a systemd timer when it is due, and installs it for
# the service that terminates TLS. No resource: the outputs are fragments of the cloud-init
# configuration of the instance.
#
# The DNS provider settings live in one place on the instance, an environment file read by the
# renewal service only: a secrets manager can write it instead.

locals {
  # Whether a client is configured is not secret, only the settings are.
  enabled = nonsensitive(var.certificates != null)

  dns_env = local.enabled ? (
    var.certificates.dns.provider == "rfc2136" ? {
      DNSUPDATE_NAMESERVER     = var.certificates.dns.settings.nameserver
      DNSUPDATE_TSIG_KEY       = var.certificates.dns.settings.tsig_key_name
      DNSUPDATE_TSIG_ALGORITHM = "${trimsuffix(var.certificates.dns.settings.tsig_algorithm, ".")}."
      DNSUPDATE_TSIG_SECRET    = var.certificates.dns.settings.tsig_secret
    } : var.certificates.dns.settings
  ) : {}

  flags = local.enabled ? join(" ", concat(
    ["--accept-tos", "--email '${var.certificates.email}'", "--server '${var.certificates.directory_url}'"],
    ["--dns '${var.certificates.dns.provider}'", "--path /var/lib/lego", "--key-type EC256"],
    # With resolvers, the TXT record is checked on them only, not on the zone's authoritative
    # servers found through the instance's resolvers (like cert-manager's
    # --dns01-recursive-nameservers-only).
    [for r in var.certificates.dns.resolvers : "--dns.resolvers '${r}'"],
    length(var.certificates.dns.resolvers) > 0 ? ["--dns.propagation.disable-ans"] : [],
    [for d in var.domains : "--domains '${d}'"],
  )) : ""
}
