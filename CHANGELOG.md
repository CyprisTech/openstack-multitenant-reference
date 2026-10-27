# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before `v1.0.0`, minor versions may contain breaking changes; each one comes with migration notes.

## [Unreleased]

### Planned

- Stack 30 `platform`: a Kubernetes cluster created with Cluster API Provider OpenStack on a project prepared by the module, its ingress published through the entry point (specified in [docs/architecture.md](docs/architecture.md), not delivered).

## [0.1.0] - 2026-10-27

First release: layers 20 and 30 of the reference architecture in one site, with layer 10 provided by the operator, built on terraform-openstack-tenant `v0.1.2` and tested on a private OpenStack 2025.1 cloud.

### Added

- ADR-0001 (scope and structure: three layers, one state per stack, shared planes, single public entry point, executable reachability matrix, site-ready code) and the architecture specification: topology, request flow, reachability matrix, layer 10 contract, sites, sizing.
- Trade-offs of every choice (TLS passthrough, health monitors, PROXY protocol, Octavia topology, the edge as a shared dependency, one site, isolation on `svc_public`, security group ownership, Kubernetes lifecycle, layer 10 by the operator), with when to choose the alternative.
- Stack `20-public-edge`, the public entry point for every domain: Octavia in TCP on 80 and 443 with PROXY protocol pools and TCP health monitors, two Traefik instances in hard anti-affinity routing by SNI with TLS passthrough and PROXY protocol v2 to the backends, routes generated from a variable, instances replaced one at a time on a route change.
- Stack `30-tenants/web`: two web instances in anti-affinity serving two domains, published on `svc_public` with a floating IP of that plane, HTTPS admitted from the entry point only, a `routes` output in the shape of the entry point's variable, demonstration nginx backend accepting PROXY protocol v2.
- Stack `30-tenants/isolated`: a workload whose only router joins the monitoring plane, with no public address and no path to the other tenants or the Internet.
- Optional bastions in the three stacks, with a floating IP on an administration network and a second port on the tenant network.
- Monitoring through floating IPs and DNS discovery: every instance gets a floating IP of the `monitoring` plane and an A record in a shared monitoring zone; metrics ports open to the collector's addresses only (`monitoring.collector_cidrs`).
- Executable reachability matrix (`tests/reachability/check.py`): probes every flow from the outside, from inside each tenant through its bastion and from the collector, and fails on any difference.
- Test collector (`tests/integration/collector`) for the matrix, and the two-floating-IP test (`tests/integration/dual-floating-ip`) behind the monitoring design.
- Test results ([docs/testing.md](docs/testing.md)): apply, empty plan after apply, HTTPS end to end through both domains, rolling replacement of the entry point, reachability matrix 27/27, destroy without leftover. Findings fed back into the layer 10 contract: reserved address ranges, path MTU (`network_mtu`), resolvers reachable at first boot.
- CI on GitHub Actions: `fmt`, `init` and `validate` of every configuration on OpenTofu and Terraform (lowest supported and latest), TFLint, syntax check of the matrix script, gitleaks over the full history. Actions pinned by commit SHA; Dependabot updates.
- Apache-2.0 license, contribution guide, Code of Conduct, security policy, support page, issue and pull request templates.

[Unreleased]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/CyprisTech/openstack-multitenant-reference/releases/tag/v0.1.0
