# Spec: certificates of the tenants

- **Status:** Implemented in v0.4 — decisions in [ADR-0008](../adr/0008-tenant-certificates.md); its release is given in the README's [status](../../README.md#status)
- **Related:** [ADR-0006](../adr/0006-exposure.md) (exposure, TLS ends in the tenant), [ADR-0004](../adr/0004-planes-and-isolation.md) (planes), [spec: a Kubernetes cluster for shared services](kubernetes-shared-services.md) (internal certificate authority)

## Problem

TLS ends in the tenant ([ADR-0006](../adr/0006-exposure.md)): the entry point routes by SNI and holds no key. Today the tenants terminate TLS with self-signed certificates — nginx on the `vm` instances, the ingress of the `kubernetes` tenant — so a browser rejects every published domain, and nothing renews.

A tenant needs certificates from one of two authorities:

- a **public authority** (Let's Encrypt), for the domains published on the Internet;
- the **certificate authority of the organisation**, for names served on the internal planes only, which must not appear in the public Certificate Transparency logs.

## Goal

Each tenant type obtains and renews its certificates with the standard tool of its platform, from either authority, with a DNS provider of the user's choice:

- `vm`: every instance terminates TLS and runs an ACME client;
- `kubernetes`: cert-manager issues the certificate of the ingress;
- shared services on Kubernetes: the internal authority of the [shared-services spec](kubernetes-shared-services.md).

Out of scope: the HTTP-01 challenge (see Proposed decisions, 1), certificates on the entry point (it does not terminate TLS), the `isolated` tenant (it serves nothing), operating the organisation's authority, central issuance and distribution of certificates (Vault and similar), and the DNS provider itself.

## Design

### 1. One mechanism: ACME with the DNS-01 challenge

Both authorities are reached the same way: an **ACME directory URL**, plus the root certificate of the authority when it is not publicly trusted. Let's Encrypt is an ACME directory; so are the common internal authorities (step-ca, Vault PKI, EJBCA). The tenant proves control of a name by writing a TXT record `_acme-challenge.<name>` in its DNS zone.

- For Let's Encrypt, the zone must resolve publicly, or `_acme-challenge.<name>` must be a CNAME to a public zone (both tools follow it).
- For an internal authority, a private zone is enough: the authority resolves it on the internal network.

### 2. Configuration, the same for both tenant types

```hcl
certificates = {
  directory_url = "https://acme-v02.api.letsencrypt.org/directory"  # or the internal authority
  ca_bundle     = null                                               # PEM, for an internal authority
  email         = "ops@example.org"
  dns = {
    provider = "rfc2136"
    # Provider settings, as the tool expects them; sensitive.
    settings = {
      nameserver     = "203.0.113.53:53"
      tsig_key_name  = "tenant-web."
      tsig_algorithm = "hmac-sha256"
      tsig_secret    = "..."
    }
  }
}
```

The example uses **RFC 2136** dynamic updates authenticated with TSIG: an IETF standard, implemented by BIND, Knot and PowerDNS, and supported natively by both lego and cert-manager. Other providers are a parameter: any [lego provider](https://go-acme.github.io/lego/dns/) on the `vm` tenant; any cert-manager solver, native or webhook, on the `kubernetes` tenant.

Each tenant gets its own TSIG key, allowed to update only the TXT records under `_acme-challenge` of its own names: a tenant cannot obtain a certificate for the names of another.

Without `certificates`, a tenant runs in demonstration mode with a self-signed certificate and a warning at every plan ([ADR-0008](../adr/0008-tenant-certificates.md), D2).

### 3. The `vm` tenant

Topology unchanged: the tenant's load balancer, then the instances, each terminating TLS (nginx in front of the application).

- **lego** on each instance, installed by cloud-init: obtains the certificate at first boot, renews it from a systemd timer when it expires within 30 days, and reloads nginx.
- **Each instance holds its own certificate and ACME account.** This is the common practice for a small number of instances. With Let's Encrypt, at most 5 certificates for the same set of names are issued per week: replacing instances often, or running many, needs central issuance instead (out of scope, documented). An internal authority sets its own limits.
- Until its certificate is issued, an instance serves nothing on 443; the load balancer's health monitor keeps it out of the pool.

A reverse-proxy tier in front of the application instances (load balancer, two proxies, then the instances) is documented in the architecture, with when to use it — several applications under one domain, routing by path, a web application firewall, application instances that must not hold keys — but not shipped as a stack.

### 4. The `kubernetes` tenant

- **cert-manager**, already in the cluster (Cluster API needs it), with an `Issuer` built from `certificates`: ACME server, `caBundle`, a DNS-01 solver (`rfc2136` in the example).
- A `Certificate` for the domains of the cluster writes the secret the ingress listener already uses; the self-signed demonstration certificate goes away.
- The ingress replicas read the same secret: one certificate for the tenant, whatever the number of replicas.

### 5. Names served on the internal planes only

The same mechanism with the internal authority: `directory_url` and `ca_bundle` point to it, and the DNS zone can be private. Clients trust the authority's root, distributed by the organisation. This is the default the [shared-services spec](kubernetes-shared-services.md) assumes for shared services.

### 6. Credentials of the DNS provider

Each tool reads the provider settings from **one place on its platform**, whatever delivers them:

- `vm`: a local environment file, `/etc/lego/dns.env`, readable by root only; the renewal service reads nothing else.
- `kubernetes`: a Secret in the cert-manager namespace, referenced by the `Issuer`.

In this release, the stack writes them: the file through the instance's user data, the Secret when the cluster is created. User data is readable by the members of the project, and from inside the instance through the metadata service; the exposure is bounded by the key itself, one per tenant, allowed to change only the TXT records `_acme-challenge` of its names.

A secrets manager plugs into the same places, as part of the secrets integration point (the README's [status](../../README.md#status)): on virtual machines, a command run at boot writes the file, for example from Vault or OpenBao with a response-wrapped, single-use secret ID, or from Barbican with an application credential restricted to that secret (OpenStack gives instances no identity of their own, so a first token is always delivered; wrapping makes it useless once used); in Kubernetes, External Secrets Operator keeps the Secret in sync. The certificate logic does not change.

### 7. Tests

The reference tests the internal-authority path, which exercises everything Let's Encrypt uses except the public Internet:

| Setup | What it proves |
|---|---|
| A test fixture `tests/fixtures/acme`, a shared service of the internal services plane standing for the organisation's DNS and authority: an authoritative DNS server (Knot) with RFC 2136 and TSIG, one key per tenant, and **step-ca**, an open-source ACME authority, validating against it. The `vm` tenant joins the internal services plane to reach it, as the `kubernetes` tenant already does | lego (`vm`) and cert-manager (`kubernetes`) obtain, serve and renew certificates through DNS-01; a client trusting the root sees a valid certificate on every published domain; a tenant's key cannot update another tenant's names |

Let's Encrypt takes the same path; only the directory URL changes, and no root is given. What the tests do not cover belongs to the public Internet and to the DNS provider: propagation of the TXT record and validation from several points of the Internet, Let's Encrypt's rate limits, CAA records. The README's status and the test results say so: *tested with an internal ACME authority; Let's Encrypt uses the same path, not tested by the maintainers*. The documentation of the examples shows the Let's Encrypt configuration (staging, then production) with these points of attention; users report what fails in an issue.

The isolation test gains rows: each published domain presents a certificate for its name, issued by the expected authority; a tenant's key cannot update another tenant's names. Other DNS providers and HTTP-01 are not tested: the tools own them. Nothing is exposed for these tests.

## Dependencies and order

1. [ADR-0008](../adr/0008-tenant-certificates.md).
2. `tests/fixtures/acme` (Knot and step-ca, private); the internal services plane as an optional plane of the `vm` tenant.
3. `vm` tenant: lego, configuration, health monitor; tests.
4. `kubernetes` tenant: `Issuer` and `Certificate`; tests.
5. Isolation rows; test results.
6. Documentation: architecture (TLS termination per tenant type, the reverse-proxy tier), trade-offs (DNS-01 only), guides with the Let's Encrypt configuration.

## Decisions

Recorded in [ADR-0008](../adr/0008-tenant-certificates.md).

## Open questions

None. A campaign against Let's Encrypt staging remains possible later, with a public DNS server for a delegated test zone, created for the campaign and removed after it; it is not a prerequisite.

In production, a self-hosted DNS usually follows the hidden-primary pattern: a private primary receives the updates, public secondaries serve the zone.
