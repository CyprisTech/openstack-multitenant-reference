# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before `v1.0.0`, minor versions may contain breaking changes; each one comes with migration notes.

## [Unreleased]

### Changed

- Kubernetes: CAAPH v0.6.6, which no longer duplicates the Helm release proxies after `clusterctl move` ([kubernetes-sigs/cluster-api-addon-provider-helm#606](https://github.com/kubernetes-sigs/cluster-api-addon-provider-helm/pull/606)). The repair in `create-cluster.sh` is removed; the script stops if a duplicate still appears.

## [0.5.1] - 2026-11-20

### Added

- Campaign tooling in Python (`tests/campaign/run.py`, standard library only), replacing the Bash `run.sh`: a scenario per profile (`private-cloud`, `public-cloud`) that also sets the inputs of the profile, a dry run, a JSON report with the duration of every step, apply and destroy, the time until the entry point answers steadily, one asciinema recording per step (`--record`), the output of the cluster scripts streamed as they run, unit tests run by CI. Validated by full campaigns in both plane modes (2026-11-19). The public cloud scenario has not run on a public cloud yet.
- Profiles in the README ([ADR-0014](docs/adr/0014-profiles.md)): the inputs that differ between `private-cloud` and `public-cloud`; each campaign scenario sets them.
- Bastion placement ([ADR-0014](docs/adr/0014-profiles.md), D2): `bastion_placement = "stack-network"` puts the bastion on the stack's network, its floating IP on the egress router (the public router for the entry point), when the administration network is the stack's egress network. It saves a network and a router per project: the stacks of the public cloud profile fit in 4 routers. The default stays `"own-network"`; the isolated tenant, with no egress, has no such input. A variable of its own, not an attribute of `bastion`: the profile's choice can be set without repeating the cloud's values of `bastion`. Mocked tests in `stacks/tenants/vm`.

### Changed

- IPv6 ([ADR-0015](docs/adr/0015-ipv6.md)): IPv4 until `v1.0`, then one address family per deployment; dual stack only once the OpenStack provider and the cloud controller support it. The Status lists IPv6 after `v1.0`; `v1.0` is tested on a private cloud (all of it) and on a public one (what differs).
- ADR-0011 to ADR-0014 accepted.
- Planes contract: two planes must not route the same destination; security group quotas; DNS is optional. Isolation matrix: what the isolated tenant reaches is what its plane routes.
- The `subnet` of an external network (`egress_network`, `public_network`, `bastion.external_network`, `admin_network`) is optional: without it, Neutron chooses. A public network with several subnets of the same name (OVHcloud's `Ext-Net`) could not be looked up by name.
- Documentation: a README introduction that covers the whole reference, both exposures included, and a [glossary](docs/concepts/glossary.md); the [architecture](docs/concepts/architecture.md) states for each part whether it is delivered or planned, and links to its detail, moved to the guides, the stacks' READMEs, a [security model](docs/concepts/security.md), [sizing and limits](docs/reference/sizing-and-limits.md) and a [spec of several regions](docs/specs/regions.md); two more [trade-offs](docs/concepts/trade-offs.md) (hub planes as shared segments, a bastion per stack).

### Fixed

- Kubernetes, repair of the duplicated CAAPH release proxies after `clusterctl move` (shipped in v0.5.0, run on a cloud for the first time on 2026-11-19): the repair ran after the bootstrap instance's address had left the API sources and could wait for hours; it now runs first, with a request timeout. Each repaired chart is installed once more from its single proxy, after the Services of its release are deleted: the uninstall of the deleted proxies removed the Service of the new release (an ingress without its load balancer). The script then waits for the load balancers of the repaired release: the cluster used to be handed over while an ingress was still without an address. Duplicates occur at the creation of a cluster, not at its upgrades.
- Kubernetes, `create-cluster.sh` run again after `clusterctl move` (an earlier run stopped later, on a certificate for example): it created the cluster a second time in an empty kind cluster, which adopted the API load balancer and waited for machines. It now continues on the cluster itself, and stops if the cluster cannot be reached. The script reaches the bootstrap instance at its creation: an apply does not update it on an existing instance.
- Kubernetes, the namespace of an ingress created by CAAPH while `create-cluster.sh` created it: the script stopped on `AlreadyExists`.
- Test ACME authority: a restart of Knot (unattended upgrades restart it in the first hour of the instance) dropped the challenge records kept in its journal only, and a certificate never became ready. Each update is now written to the zone file.

### Known issues

- No in-place upgrade from v0.4: the apply fails on every tenant with an egress, the gateway address staying on the egress router's port (tested on 2026-11-20; the v0.5.0 note above that the apply replaces that port is wrong). Redeploy the tenant stacks: destroy with v0.4, apply with v0.5. The planes stack upgrades in place.

## [0.5.0] - 2026-11-18

### Added

- [ADR-0011](docs/adr/0011-environments.md): environments, two tiers with a landing zone each, the same code with declared differences, promotion by artifact, a deployment repository with one directory per tier; a non-production tier kept off the Internet by its entry point.

- Guide [existing projects](docs/guides/existing-projects.md): why move, three ways chosen per project (connect, take over, rebuild beside), and how to proceed with thousands of objects (one stack per project, an inventory generated from the API, `import` with `for_each`).
- Availability zones ([ADR-0012](docs/adr/0012-resilience-scope.md)): input `zones` (a list, at least one) on the `vm`, `isolated`, `entry-point`, `kubernetes` and shared `kubernetes` stacks. The instances of a role are spread over the zones in order, the single ones (bastion, isolated workload, bootstrap instance) go to the first. Kubernetes: the control plane is spread by Cluster API, the workers get one machine deployment per zone; a warning when the quorum of the control plane does not survive the loss of a zone.
- Input `volume_zones`: the block storage zone of the root volumes for each compute zone; a compute zone missing from the map gets the cloud's default storage zone. The root volumes of the Kubernetes machines take the zone of their machine.
- Tests with a mocked OpenStack provider (`tofu test`), run by CI: placement over zones in each stack, quorum warning of the Kubernetes module.
- [ADR-0012](docs/adr/0012-resilience-scope.md): what the reference places, what the cloud and the workloads provide, what is tested; the documentation says which resilience claims are tested.
- README: the member role up front, the layers in *Scope*, the reference next to a provider's landing zone; audiences: OpenShift in a tenant project, outside the reference.
- Guide [rebuild](docs/guides/rebuild.md): what to keep outside the cloud, the order of the stacks, what to rebuild for each loss.
- `tests/campaign`: a step `volume` on the shared cluster; the credential rotation also provisions a volume and moves an existing one, checked again after the upgrade.
- `tests/campaign`: `NOTIFY_STEPS=1` tells the operator the start and end of each step; a `leftovers` step checks that nothing is left in the projects after the teardown; the sizes the maintainers use, documented.
- Isolation test: a positive control per source, and a row from the shared cluster to the receiver; a source whose closed results come with no reachable target fails the test.
- `tests/campaign`: after a return from direct exposure (`direct`, `direct-k8s`), the domains are probed again through the entry point, once it answers steadily; `direct-k8s` deploys the demo application itself.

### Changed

- **Breaking:** plane routes on a transit router ([ADR-0013](docs/adr/0013-plane-routes-on-a-transit-router.md)). Every tenant subnet gets a transit router with no external gateway, which holds the gateway address and a route to each plane through that plane's router; the subnet pushes no host routes any more. Octavia load balancers copy host routes once, when their VIP is plugged: after an exposure change or a plane joined later, they kept a dead next hop and answered no client of the plane. `plane-attachment`: input `default_gateway` replaced by `default_router` (`isolated`: `"observability"`), new input `routes`; one router more per stack, to plan in the router quotas. Migration of a running tenant: the apply replaces the egress router's port on the subnet (the gateway address moves to the transit router), which stops outbound Internet traffic while it runs; not tested on a running tenant.
- Every stack uses `terraform-openstack-tenant` `v0.1.6` (routes with a next hop named by router).
- Kubernetes: `create-cluster.sh` repairs the duplicate Helm release proxies of CAAPH after the move (kubernetes-sigs/cluster-api-addon-provider-helm#606) instead of ending in error: both proxies of each duplicated chart are deleted and CAAPH installs the chart again. Every cluster creation of the 2026-11-18 campaigns had duplicates.
- Test fixture `internal-service`: `allowed_sources` defaults to empty, the service closed; the campaign and the test procedure create it before its consumers and open it after them, in place.
- Test fixtures take `zones` instead of `az`, as the stacks.
- `tests/campaign`: no load during the first publication of a campaign, nor during the return from direct exposure (the domains were not served); the teardown resets the first-publication marker.
- `tests/campaign`: an instance whose cloud-init ends in error stops the campaign; scenes that change a stack and restore it can be run again after a failure.
- Kubernetes: the default storage class is `csi-cinder`, created by `create-cluster.sh`: a volume is created once its pod is placed (`WaitForFirstConsumer`). With `volume_zones` mapping every zone to one storage zone (shared storage, such as one Ceph behind all zones), volumes are created in that storage zone and may follow their pod to any zone (`ignore-volume-az` for Cinder CSI); otherwise in the zone of their node, which Cinder must have under the same name. Storage zones of other names per zone are not supported (a check warns). The chart's classes stay, no longer default; existing clusters: apply the class from `create-cluster.sh` once, existing claims are not affected.
- **Breaking:** input `az` (a string) replaced by `zones` (a list). Migration: `az = "nova"` becomes `zones = ["nova"]`; with one zone, the VM stacks plan no change. The Kubernetes templates get a new revision: Cluster API replaces the machines once, one by one, at the next apply, as for a template change.

### Fixed

- `delete-cluster.sh`: a cluster whose creation stopped before `clusterctl move` is still managed by the bootstrap instance; it is now deleted from there, instead of failing on the workload API. Without a cluster and without its kubeconfig, the script has nothing to delete and says so.
- `tests/campaign`: the teardown no longer takes a cluster that was never moved for an absent one, which left its servers and load balancers behind the destroyed stack.

## [0.4.0] - 2026-11-12

### Added

- `kubernetes`: input `exposure` (`"entry-point"` or `"public"`), as for `vm`: exposed directly, the cluster's ingress gets a floating IP of the egress network and the cluster does not join the publication plane; output `service_address`. Module `kubernetes-cluster`: an entry with `plane = "egress"`.
- Kubernetes: the cloud controller may delete nodes, so that the Node of a replaced machine goes away after an upgrade.
- Kubernetes: a root volume size of 0 boots the machines from the flavor's local disk.
- Kubernetes lifecycle ([guide](docs/guides/kubernetes-lifecycle.md)): upgrade with one node image per version, selected by a variable of the ClusterClass; rotation of the cluster's credential. Tested in the campaign.
- `tests/campaign`: the test campaign as a script, with asciinema recordings of each step and a sanitiser for publishing them.
- Certificates of the tenants ([ADR-0008](docs/adr/0008-tenant-certificates.md)): input `certificates` on the `vm` and `kubernetes` stacks — ACME DNS-01 from any directory (Let's Encrypt or the organisation's authority), lego on the instances (local module `acme-client`), cert-manager in the cluster, RFC 2136 with TSIG in the examples. Without it, demonstration mode (self-signed, with a warning). Guide [certificates](docs/guides/certificates.md).
- `vm`: joins the internal services plane when its attachment has it; output `internal_sources`.
- Test fixture `tests/fixtures/acme` (Knot and step-ca, one TSIG key per tenant); isolation rows for certificates and TSIG keys (`--acme`).
- `admission` module: UDP flows.
- OpenSSF Best Practices badge (passing).
- `CODEOWNERS`: the maintainers team reviews every change; ADRs name the maintainers as deciders.
- CodeQL workflow: static analysis of the GitHub Actions workflows and the Python scripts (HCL is not supported by CodeQL).
- Module `kubernetes-cluster`, extracted from the `kubernetes` stack ([ADR-0009](docs/adr/0009-kubernetes-lifecycle.md)): the planes it joins, `ingresses` (one Traefik deployment, Gateway and Service each) and layer 4 `services` as inputs, each at an address prepared by Terraform; outputs `entries` and `sources` per plane. The `kubernetes` stack calls it with its public ingress; its inputs and outputs are unchanged, `moved` blocks keep existing resources. The template revision changes once: Cluster API replaces the machines one by one at the next apply.
- Stack `stacks/shared/kubernetes`: a Kubernetes cluster for shared services, not published, with an internal ingress and demonstrated services ([ADR-0010](docs/adr/0010-kubernetes-shared-services.md)); isolation rows with `check.py --shared-kubeconfig`.

### Changed

- Module `kubernetes-cluster`: the bootstrap instance and its security group in their own call of `terraform-openstack-tenant`, so that a change of exposure no longer blocks on the router interfaces nor replaces the bootstrap instance. Existing clusters: with `bootstrap = true`, the bootstrap instance is replaced once (copy the cluster credential to it again); the node deletion right is applied by `create-cluster.sh`, apply it by hand to a cluster created before (see `modules/kubernetes-cluster/scripts/create-cluster.sh.tftpl`).
- `tenants/vm` exposed directly (`exposure = "public"`) no longer joins the publication plane: its attachment needs no publication, and the entry point cannot reach it.
- Every stack uses `terraform-openstack-tenant` `v0.1.5`: replacing a router no longer leaves its interface on a deleted port.
- Plane keys named by role: `svc_public` → `publication`, `monitoring` → `observability`, `intranet` → `internal`, in `shared/planes`, the stacks and the fixtures. Outputs `publication_sources` (entry point, was `svc_public_sources`) and `internal_sources` (`vm`, `kubernetes`, was `intranet_sources`); test fixture `tests/fixtures/internal-service` (was `intranet-service`), `check.py --internal-service`. The scenario's network names remain only as the names of the operator networks in the examples. Existing deployments: re-key the planes and the attachments in the `terraform.tfvars` of `shared/planes`, then give each stack its new `plane_attachment`; the routers of the planes are recreated (no `moved` blocks before `v1.0.0`).
- `kubernetes`: outputs `manifests` and `scripts` are sensitive (they may hold the DNS provider's key).
- README badges: tested OpenStack release, OpenSSF Scorecard; OpenSSF Scorecard workflow (weekly and on every push to `main`).
- Kubernetes tenant: the cluster, the attachment key, the TLS secret and the resource prefix are renamed from `platform` to `published`, and `tests/isolation/check.py --platform-kubeconfig` becomes `--published-kubeconfig`. Existing deployments: re-key the attachment in `shared/planes`; the resources named after the prefix are recreated.
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

[Unreleased]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/CyprisTech/openstack-multitenant-reference/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/CyprisTech/openstack-multitenant-reference/releases/tag/v0.1.0
