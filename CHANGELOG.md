# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before `v1.0.0`, minor versions may contain breaking changes; each one comes with migration notes.

## [Unreleased]

One account, one project per tenant: the shared planes can be built by the account holder on a public cloud, every stack runs in its own project, and the repository is reorganised by role. **Breaking**: paths and some inputs (migration notes below).

### Added

- ADR-0003: scope (one account, one project per tenant or shared service, the hub project holding the network only) and the two ways the planes are provided — by the operator (gateway mode, as before) or as private networks of a hub project shared by RBAC and joined through a transit router (interface mode).
- Stack `shared/planes`: adopts operator planes, or creates shared private planes with their RBAC policies and transit routers; attachments with a role per plane; routes generated for every attachment; discovery of the attached routers' addresses; overlap checks.
- `stacks/shared/planes` as the single description of the planes for every stack, adopted or built; `plane_attachment` the only plane input of the stacks. In interface mode, routers with an interface on the plane and routes through the transit router, instances reached at their own address, Kubernetes Services on internal load balancers at fixed addresses (`service_addresses`).
- Local modules `plane-attachment`, `bastion` and `admission` (the logic every stack repeated, written once), `plane-discovery` and `range-overlaps` (the technical parts of `shared/planes`).
- Outputs `svc_public_sources` (entry point) and `intranet_sources` (Kubernetes tenant); inputs `edge_sources` and `allowed_sources`, so that no stack reads an object of another project.
- Documentation by task: concepts (architecture, how a tenant joins a plane, connecting two tenants, trade-offs, landscape, test results), guides (add a tenant, publish a domain, check the isolation, Kubernetes tour, teardown), reference (test procedure, isolation matrix, planes contract, integration points), one getting started for every cloud, with the configuration of the planes per context (`examples/planes`); spec of a Kubernetes cluster for shared services.
- Isolation test: tenant-to-tenant rows at the private addresses; the hostile-route case in the test procedure.
- CI validates and lints the Kubernetes tenant and the test fixtures.

### Changed

- Domain publication renamed, so that "routes" only means network routes: script `scripts/publish-domains.sh` (was `publish-routes.sh`), input `domains` of the entry point (was `routes`), output `published_domains` of the tenants (was `routes`), file `domains.auto.tfvars.json` (was `routes.auto.tfvars.json`). The script now stops when a deployed tenant's state lacks the output (apply it first), and refuses to remove every published domain unless `--allow-empty`: either case used to replace the entry point instances with a configuration routing nothing.
- The rules of the security groups are keyed `<flow>-<port>-<source>` (module `admission`): on an existing deployment they are replaced, with the same content.
- `cloudinit` is referenced at the published tag `v0.1.3`.

### Fixed

- `shared/planes`: the first apply on an empty project.

### Migration from 0.2.x

| Before | After |
|---|---|
| `stacks/20-public-edge` | `stacks/shared/entry-point` |
| `stacks/30-tenants/web` | `stacks/tenants/vm` |
| `stacks/30-tenants/isolated` | `stacks/tenants/isolated` |
| `stacks/30-tenants/platform` | `stacks/tenants/kubernetes` |
| `tests/reachability` | `tests/isolation` |
| `tests/integration/collector`, `tests/integration/intranet-service` | `tests/fixtures/collector`, `tests/fixtures/intranet-service` |
| every stack: input `planes` (operator networks), `isolated` and collector `monitoring_plane`, intranet service `intranet` | input `plane_attachment` only, from the `attachments` output of `stacks/shared/planes`, which adopts the operator's planes (`examples/planes/operator.tfvars.example`) |
| intranet service fixture: sources read by name | input `allowed_sources` |
| `scripts/publish-routes.sh` | `scripts/publish-domains.sh` |
| entry point: input `routes`, output `routes`, file `routes.auto.tfvars.json` | input `domains`, output `domains`, file `domains.auto.tfvars.json` (rename the file and its top-level key) |
| tenants: output `routes` | `published_domains` (apply the tenants before publishing) |
| entry point: output `svc_public_source_ips` (addresses) | `svc_public_sources` (CIDR ranges) |
| `vm`, `kubernetes`: entry point read by name | input `edge_sources` (output `svc_public_sources` of the entry point); `vm` still reads it by name when `null` and in the same project |

States are not affected by the moves: move each stack's state with its directory.

## [0.2.1] - 2026-10-29

Fixes from two full test cycles (teardown and rebuild), and the test procedure. No change of interface.

### Added

- Test procedure (`docs/test-procedure.md`): every step of a full cycle with its checkpoint, measured duration and the folded output of a real run; step 4b removes the bootstrap instance once the cluster manages itself.
- Results of the two cycles of 2026-10-29 in `docs/testing.md`: `delete-cluster.sh` without manual step, capacity per host for the hard anti-affinity of the entry point, Designate delays on shared zones.

### Fixed

- `publish-routes.sh` replaces unhealthy entry point instances first and never the last healthy one; it waits for each replaced instance only. It could cut the entry point when one instance was already broken.
- cloud-init retries package downloads (entry point, `web`, platform bootstrap): a mirror error at first boot left an instance without its packages, unnoticed.

## [0.2.0] - 2026-10-28

The Kubernetes `platform` tenant, built with Cluster API, and everything it needs: node image, route publication, reachability rows, hardening, teardown tested.

### Added

- ADR-0002, the `platform` tenant: Kubernetes with Cluster API, self-managed after `clusterctl move`, Cilium, Traefik with the Gateway API, Prometheus federated by the collector, Kubernetes API on the administration network, administration and intranet as two roles.
- Stack `30-tenants/platform`: cluster network with its routers to the planes, server groups, bootstrap instance, floating IPs of the ingress and of Prometheus with the monitoring record, Cluster API manifests (ClusterClass, `Cluster`, add-ons installed by CAAPH) and the scripts that create and delete the cluster. Every version is pinned.
- Node image built with image-builder in the project itself (`images/kubernetes-node`), with a boot check (`tests/integration/node-image`).
- Machine remediation (MachineHealthCheck), control-plane replacement before certificate expiry, kubelet serving certificates approved by kubelet-csr-approver, metrics-server.
- `scripts/publish-routes.sh`: collects the `routes` output of every tenant and replaces the entry point instances one at a time, resumable after a failure.
- Reachability matrix: 15 platform rows (ingress, federation, Kubernetes API, intranet service), with the intranet demonstration service `tests/integration/intranet-service`.
- Documentation: technology landscape, network topology and data paths, platform tour regenerated from a test deployment (`tests/tour/capture.py`), quick start, specification of plane bindings on public clouds (later milestone).
- CI: documentation links and anchors checked, script syntax checked.

### Changed

- ADR-0001: D4 refined by ADR-0002; open points resolved.
- Teardown: `delete-cluster.sh` checks that the API admits the bootstrap instance, declares the ORC image again after the move back, and removes an orphaned control-plane hook; READMEs give the destroy order.
- Test results ([docs/testing.md](docs/concepts/test-results.md)): platform deployment, matrix 43/43, rolling replacement of every machine, Service addresses kept across a reinstall, nine defects found and fixed.

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
- Test results ([docs/testing.md](docs/concepts/test-results.md)): apply, empty plan after apply, HTTPS end to end through both domains, rolling replacement of the entry point, reachability matrix 27/27, destroy without leftover. Findings fed back into the layer 10 contract: reserved address ranges, path MTU (`network_mtu`), resolvers reachable at first boot.
- CI on GitHub Actions: `fmt`, `init` and `validate` of every configuration on OpenTofu and Terraform (lowest supported and latest), TFLint, syntax check of the matrix script, gitleaks over the full history. Actions pinned by commit SHA; Dependabot updates.
- Apache-2.0 license, contribution guide, Code of Conduct, security policy, support page, issue and pull request templates.

[Unreleased]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/CyprisTech/openstack-multitenant-reference/releases/tag/v0.1.0
