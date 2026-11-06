# Certificates of the tenants

How a tenant gets certificates its clients trust ([ADR-0008](../adr/0008-tenant-certificates.md), [architecture](../concepts/architecture.md#certificates)). The `vm` and `kubernetes` tenant stacks take the same `certificates` input.

## Demonstration mode

Without `certificates`, the tenant serves a **self-signed certificate**, and every plan warns *certificates not set: self-signed certificate, for evaluation only*. Clients must skip verification (`curl -k`). Use it to evaluate the reference, never in production.

## With the organisation's authority

For names served on the internal planes, or when the organisation runs its own ACME authority (step-ca, Vault PKI, EJBCA):

```hcl
certificates = {
  directory_url = "https://acme.example.org/acme/acme/directory"
  ca_bundle     = file("root.pem")     # the authority's root certificate
  email         = "ops@example.org"
  dns = {
    provider = "rfc2136"
    settings = {
      nameserver     = "192.0.2.53:53"
      tsig_key_name  = "tenant-web"
      tsig_algorithm = "hmac-sha256"
      tsig_secret    = "..."            # from a secrets store, never committed
    }
    resolvers = ["192.0.2.53:53"]       # when the zone is not in the public DNS
  }
}
```

The tenant must reach the authority and the DNS server: in the reference, they are shared services of the internal services plane, which the tenant joins through its entry in `shared/planes`. Clients trust the authority's root, distributed by the organisation. This is the path the reference tests, with the [test ACME authority](../../tests/fixtures/acme/README.md).

## With Let's Encrypt

The same input, with Let's Encrypt's directory and no `ca_bundle`. Start with the **staging** directory, then switch to production:

| Directory | URL |
|---|---|
| Staging (certificates not trusted, generous limits) | `https://acme-staging-v02.api.letsencrypt.org/directory` |
| Production | `https://acme-v02.api.letsencrypt.org/directory` |

Points of attention, outside the reference itself:

- **The zone must resolve publicly**, or `_acme-challenge.<name>` must be a CNAME to a public zone; leave `resolvers` empty.
- **Rate limits**: at most 5 certificates per week for the same set of names. Each `vm` instance requests its own: many instances, or frequent replacements, need central issuance.
- **CAA records**, if the zone has any, must allow `letsencrypt.org`.
- **Certificate Transparency**: every certificate, hence every name, is published.
- The instances and the cluster need to reach the directory over the Internet (egress).

This path uses the same tools and configuration as the tested one; it is not tested by the maintainers. Report what fails in an issue.

## Other DNS providers

- `vm`: any [lego DNS provider](https://go-acme.github.io/lego/dns/): set `dns.provider` to its code and `dns.settings` to its environment variables.
- `kubernetes`: any cert-manager DNS-01 solver: set `dns.solver` to the solver, and create its credentials Secret in the `cert-manager` namespace.

## Credentials

The DNS provider's credentials reach the instances (`/etc/lego/dns.env`, root only) and the cluster (a Secret in `cert-manager`) through user data, readable by the members of the project. Give a key restricted to the `_acme-challenge` records of the tenant's names. A secrets manager can write the same places instead, as part of the secrets integration point ([spec](../specs/tenant-certificates.md#6-credentials-of-the-dns-provider)).
