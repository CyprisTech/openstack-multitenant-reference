# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before `v1.0.0`, minor versions may contain breaking changes; each one comes with migration notes.

## [Unreleased]

### Added

- Certificates of the tenants ([ADR-0008](docs/adr/0008-tenant-certificates.md)): input `certificates` on the `vm` and `kubernetes` stacks — ACME DNS-01 from any directory (Let's Encrypt or the organisation's authority), lego on the instances (local module `acme-client`), cert-manager in the cluster, RFC 2136 with TSIG in the examples. Without it, demonstration mode (self-signed, with a warning). Guide [certificates](docs/guides/certificates.md).
- `vm`: joins the internal services plane when its attachment has it; output `internal_sources`.
- Test fixture `tests/fixtures/acme` (Knot and step-ca, one TSIG key per tenant); isolation rows for certificates and TSIG keys (`--acme`).
- `admission` module: UDP flows.
- OpenSSF Best Practices badge (passing).
- `CODEOWNERS`: the maintainers team reviews every change; ADRs name the maintainers as deciders.
- CodeQL workflow: static analysis of the GitHub Actions workflows and the Python scripts (HCL is not supported by CodeQL).
- Module `kubernetes-cluster`, extracted from the `kubernetes` stack ([ADR-0009](docs/adr/0009-kubernetes-lifecycle.md)): the planes it joins, `ingresses` (one Traefik deployment, Gateway and Service each) and layer 4 `services` as inputs, each at an address prepared by Terraform; outputs `entries` and `sources` per plane. The `kubernetes` stack calls it with its public ingress; its inputs and outputs are unchanged, `moved` blocks keep existing resources. The template revision changes once: Cluster API replaces the machines one by one at the next apply.
- Stack `stacks/shared/kubernetes`: a Kubernetes cluster for shared services, not published, with an internal ingress and demonstrated services ([spec](docs/specs/kubernetes-shared-services.md)); isolation rows with `check.py --shared-kubeconfig`.

### Changed

- Plane keys named by role: `svc_public` → `publication`, `monitoring` → `observability`, `intranet` → `internal`, in `shared/planes`, the stacks and the fixtures. Outputs `publication_sources` (entry point, was `svc_public_sources`) and `internal_sources` (`vm`, `kubernetes`, was `intranet_sources`); test fixture `tests/fixtures/internal-service` (was `intranet-service`), `check.py --internal-service`. The scenario's network names remain only as the names of the operator networks in the examples. Existing deployments: re-key the planes and the attachments in the `terraform.tfvars` of `shared/planes`, then give each stack its new `plane_attachment`; the routers of the planes are recreated (no `moved` blocks before `v1.0.0`).
- `kubernetes`: outputs `manifests` and `scripts` are sensitive (they may hold the DNS provider's key).
- README badges: tested OpenStack release, OpenSSF Scorecard; OpenSSF Scorecard workflow (weekly and on every push to `main`).
- ADR-0003 to ADR-0007 accepted; ADR-0001 and ADR-0002 superseded in part by ADR-0006 and ADR-0007.

## [0.3.0] - 2026-11-04

One project per tenant and per shared service, deployed in one region of a cloud: the shared planes can be built with a member role on a public cloud, every stack runs in its own project, and the repository is reorganised by role. Tenants are exposed by service addresses, domains are published in seconds without replacing anything, and monitoring becomes a push integration point. **Breaking**: paths, some inputs and the monitoring contract (migration notes below).

### Added

- ADR-0003 to ADR-0007 (proposed): scope, audience and boundary of the reference (a deployment = your projects in one region, one per tenant or shared service, the hub project holding the network only); shared planes described by two properties — how a tenant router joins them and whether addresses are translated — provided by the operator or built in a hub project and joined through a transit router, with the security model; stacks and their contracts; exposure of the tenants by service addresses; monitoring as a push integration point. Page [who it is for](docs/concepts/audiences.md).
- Stack `shared/planes`: adopts operator planes, or creates shared private planes with their RBAC policies and transit routers; attachments with a role per plane; routes generated for every attachment; discovery of the attached routers' addresses; overlap checks.
- `stacks/shared/planes` as the single description of the planes for every stack, adopted or built; `plane_attachment` the only plane input of the stacks. In interface mode, routers with an interface on the plane and routes through the transit router, instances reached at their own address, Kubernetes Services on internal load balancers at fixed addresses (`service_addresses`).
- Local modules `plane-attachment`, `bastion` and `admission` (the logic every stack repeated, written once), `plane-discovery` and `range-overlaps` (the technical parts of `shared/planes`).
- Outputs `svc_public_sources` (entry point) and `intranet_sources` (Kubernetes tenant); inputs `edge_sources` and `allowed_sources`, so that no stack reads an object of another project.
- Documentation by task: concepts (architecture, how a tenant joins a plane, connecting two tenants, trade-offs, landscape, test results), guides (add a tenant, publish a domain, check the isolation, Kubernetes tour, teardown), reference (test procedure, isolation matrix, planes contract, integration points), one getting started for every cloud, with the configuration of the planes per context (`examples/planes`); spec of a Kubernetes cluster for shared services.
- `vm`: one service address per tenant — a load balancer above one instance (`instance_count`) — published through the entry point or with its own public floating IP (`exposure`); output `service_address` ([ADR-0006](docs/adr/0006-exposure.md)).
- Entry point: routes delivered as instance metadata and rendered by a timer on each instance into Traefik's dynamic configuration; a domain change updates the instances in place.
- Monitoring by push ([ADR-0007](docs/adr/0007-monitoring.md)): input `monitoring.receiver` in every stack; local module `metrics-agent` (Prometheus in agent mode) on the entry point and `vm` instances; OTLP from the `isolated` stand-in workload; remote write from the Kubernetes tenant's Prometheus. Test fixture `tests/fixtures/receiver` (Prometheus 3 with its remote-write and OTLP receivers, behind a bastion).
- Isolation test: tenant-to-tenant rows at the private addresses; service addresses reached by the entry point only; every tenant reaching the receiver and pushing series; nothing reaching a tenant's metrics ports; the hostile-route case in the test procedure.
- CI validates and lints the Kubernetes tenant and the test fixtures.

### Changed

- `scripts/publish-domains.sh` applies the entry point instead of replacing its instances one at a time: about 30 seconds instead of 5 to 8 minutes, no lost request.
- `plane-attachment`: at most one floating IP per address; extra floating IPs and DNS records on the monitoring plane removed.
- Domain publication renamed, so that "routes" only means network routes: script `scripts/publish-domains.sh` (was `publish-routes.sh`), input `domains` of the entry point (was `routes`), output `published_domains` of the tenants (was `routes`), file `domains.auto.tfvars.json` (was `routes.auto.tfvars.json`). The script now stops when a deployed tenant's state lacks the output (apply it first), and refuses to remove every published domain unless `--allow-empty`: either case used to replace the entry point instances with a configuration routing nothing.
- The rules of the security groups are keyed `<flow>-<port>-<source>` (module `admission`): on an existing deployment they are replaced, with the same content.
- Every stack uses `terraform-openstack-tenant` at the published tag `v0.1.4` (router interfaces on other networks and static routes).
- README and documentation: the reference presented as a landing zone for OpenStack, by design area; the documentation describes the `v1.0` design and a single [status](README.md#status) maps each area to its release; planes named by role; test results open on the current state; specs with an index, a life cycle and a template.
- Inputs and outputs tables of every stack, fixture and local module generated by terraform-docs, checked by the CI.
- `vm`: `edge_sources` is required, like in the Kubernetes tenant; the entry point is no longer read by name.
- `kubernetes`: on an intranet plane without NAT, `admin_network` is required (the API and the bootstrap instance need floating IPs on an external network).
- `shared/planes` refuses the hub project as an attachment: shared services run in their own projects.
- Plane examples (`examples/planes`) complete for every stack of the reference: `intranet` plane, intranet service attachment, aggregates per plane.

### Removed

- `tests/integration/dual-floating-ip`: the reference no longer puts floating IPs of several networks on one port ([ADR-0006](docs/adr/0006-exposure.md), D4).

### Fixed

- `shared/planes`: the first apply on an empty project.
- `isolated`: the bastion network took the range of the `vm` bastion (`10.31.0.0/28`) instead of its own (`10.33.0.0/28`): a deployed `isolated` bastion is replaced on the next apply, unless `bastion.cidr = "10.31.0.0/28"` keeps it.
- Getting started: commands run from the root of the repository; `isolated` takes no `edge_sources`.

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
| `vm`, `kubernetes`: entry point read by name | input `edge_sources`, required (output `svc_public_sources` of the entry point) |

| `vm`: `published_domains` to each instance (floating IPs of `svc_public`) | to the tenant's service address (its load balancer): apply the tenant, then publish |
| `monitoring = { dns_zone, metrics_ports, collector_cidrs }` in every stack; collector scraping the tenants; Kubernetes `prometheus` output and federation load balancer | `monitoring = { receiver }`: your receiver of Prometheus remote write; the floating IPs and records of the monitoring plane are destroyed by the next apply |
| `tests/fixtures/collector` | `tests/fixtures/receiver` |
| Kubernetes `service_addresses.prometheus` | removed |

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

[Unreleased]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/CyprisTech/openstack-multitenant-reference/releases/tag/v0.1.0
