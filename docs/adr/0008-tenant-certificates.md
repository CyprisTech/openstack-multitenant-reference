# ADR-0008: Certificates of the tenants

- **Status:** Proposed
- **Date:** 2026-11-05
- **Deciders:** maintainers
- **Refines:** [ADR-0006](0006-exposure.md) D5 (certificates by ACME DNS-01, in the tenant): authorities, tools, DNS provider, topology of the `vm` tenant. Design details: [spec](../specs/tenant-certificates.md).

## Context

TLS ends in the tenant ([ADR-0006](0006-exposure.md)): the entry point routes by SNI and holds no key. Up to `v0.3`, the tenants terminate TLS with self-signed certificates: nginx on the `vm` instances, the ingress of the `kubernetes` tenant.

A tenant needs certificates from a public authority (Let's Encrypt) for names published on the Internet, or from the organisation's authority for names served on internal planes only, which must not appear in the public Certificate Transparency logs. The two tenant types run on different platforms, whose standard ACME tools do not support the same DNS providers. Most users do not host their public zones in OpenStack Designate.

## Options considered

**Challenge**

1. **HTTP-01.** The most common challenge, independent of the DNS provider. It needs port 80 reachable from the authority: on the `kubernetes` tenant, through the entry point forwarding `/.well-known/acme-challenge/`; on a `vm` tenant of several instances behind a load balancer, a challenge may reach an instance that did not request it. Unusable for names served on internal planes only.
2. **DNS-01** (chosen).

**Authority**

1. **Let's Encrypt only.** Leaves out internal names.
2. **Any ACME directory, public or internal, with an optional root certificate** (chosen). Let's Encrypt and the common internal authorities (step-ca, Vault PKI, EJBCA) speak ACME.

**Tool on virtual machines**

1. **certbot.** The most widespread client; its DNS plugins cover fewer providers.
2. **Traefik's built-in ACME.** An extra component in front of the application; no shared certificate storage between replicas in the open-source edition.
3. **TLS terminated by the load balancer** (Octavia with Barbican). Not on every cloud, renews nothing, and a TLS listener does not read the PROXY header: the client address would be lost.
4. **lego** (chosen). Covers more than 150 DNS providers, including RFC 2136.

**Tool in Kubernetes:** cert-manager, the standard (a CNCF graduated project), already in the cluster for Cluster API. No alternative considered.

**DNS provider of the example**

1. **OpenStack Designate.** Supported natively by lego, only through community webhooks by cert-manager; rarely where users keep public zones.
2. **A commercial DNS API.** Ties the example to one company.
3. **RFC 2136 with TSIG** (chosen). An IETF standard, implemented by BIND, Knot and PowerDNS, supported natively by lego and cert-manager.

## Decision

### D1 — DNS-01 only

Certificates are obtained with the ACME DNS-01 challenge: it works for published and internal names, for any number of instances, allows wildcard certificates, needs no inbound port 80, and fits an entry point that does not decrypt. HTTP-01 is documented as a possible extension for public `kubernetes` tenants, not implemented.

### D2 — The authority is an ACME directory

A tenant's configuration gives the directory URL, an optional root certificate, and the DNS provider. Let's Encrypt for names published on the Internet; the organisation's authority for names served on internal planes only. cert-manager's other issuers (CA, Vault) remain available on the `kubernetes` tenant.

**Without `certificates`, a tenant runs in demonstration mode**: it serves a self-signed certificate, as up to `v0.3`, and every plan and apply warns *certificates not set: self-signed certificate, for evaluation only* (a `check` block). The mode lets a reader evaluate the reference without a DNS provider or an authority; the getting-started guide names it, and the production guide requires `certificates`. Both paths produce the same artefact in the same place (the certificate files of nginx, the `platform-tls` secret of the ingress): only how it is obtained differs.

### D3 — The standard tool per platform

lego on virtual machines, cert-manager in Kubernetes. The DNS provider is a parameter: any lego provider on the `vm` tenant, any cert-manager solver on the `kubernetes` tenant.

### D4 — RFC 2136 with TSIG in the example

One TSIG key per tenant, allowed to update only the TXT records under `_acme-challenge` of its own names: a tenant cannot obtain a certificate for the names of another.

### D5 — The `vm` instances terminate TLS

Each instance runs lego, holds its own certificate and ACME account, and serves nothing on 443 until it has one. A reverse-proxy tier in front of the application instances is documented, with when to use it, not shipped. With Let's Encrypt, at most 5 certificates for the same set of names are issued per week: many instances, or frequent replacements, need central issuance, which is out of scope.

### D6 — Tested with an internal ACME authority

The tests use step-ca and a private Knot server: they exercise the tools, DNS-01 through RFC 2136, the isolation of the keys, issuance, renewal and the trust of a root. Let's Encrypt takes the same path with another directory URL and is documented, not tested by the maintainers; the status and the test results say so.

## Consequences

- The tenants serve certificates a client can verify; the self-signed demonstration certificates go away.
- **Not breaking**: `certificates` is optional; without it, the `v0.3` behaviour remains, with a warning.
- Two paths to keep consistent in each tenant stack: demonstration (self-signed) and ACME. The tests use the ACME path; the demonstration mode is checked to start.
- A test fixture `tests/fixtures/acme` (Knot and step-ca) on the internal services plane, which the `vm` tenant joins as an optional plane; new isolation rows.
- What depends on the public Internet (propagation, validation from several points, rate limits, CAA records) is documented and reported by users, not tested.
