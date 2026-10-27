# openstack-multitenant-reference

A reference architecture for a multi-tenant OpenStack cloud, built on the
[terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) module.

> **Status: design phase.** No code yet. The design is recorded in
> [ADR-0001](docs/adr/0001-reference-architecture.md) and specified in
> [docs/architecture.md](docs/architecture.md).

## What it shows

- Shared network planes (intranet, monitoring, public services) that each tenant joins only as needed.
- A single public entry point for many domains: Octavia in TCP mode in front of two Traefik replicas,
  routing by SNI without terminating TLS, client address preserved with the PROXY protocol.
- Kubernetes clusters created with Cluster API Provider OpenStack on infrastructure prepared by Terraform.
- Tenant isolation, checked by an executable reachability matrix.

## Documentation

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Topology, flows, reachability matrix, layer 10 contract, sizing |
| [docs/trade-offs.md](docs/trade-offs.md) | What each choice costs and when the alternative is better |
| [docs/adr/](docs/adr/README.md) | Architecture decision records |
