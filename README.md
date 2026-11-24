# openstack-multitenant-reference

[![CI](https://github.com/CyprisTech/openstack-multitenant-reference/actions/workflows/ci.yml/badge.svg)](https://github.com/CyprisTech/openstack-multitenant-reference/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/CyprisTech/openstack-multitenant-reference?sort=semver&label=Release)](https://github.com/CyprisTech/openstack-multitenant-reference/releases)
[![OpenTofu >= 1.9](https://img.shields.io/badge/OpenTofu-%3E%3D1.9-ffda18?logo=opentofu)](https://opentofu.org)
[![Terraform >= 1.9](https://img.shields.io/badge/Terraform-%3E%3D1.9-844fba?logo=terraform)](https://www.terraform.io)
[![Tested on OpenStack 2025.1](https://img.shields.io/badge/Tested%20on-OpenStack%202025.1%20%28Epoxy%29-red)](docs/concepts/test-results.md)
[![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/CyprisTech/openstack-multitenant-reference?label=OpenSSF%20Scorecard)](https://scorecard.dev/viewer/?uri=github.com/CyprisTech/openstack-multitenant-reference)
[![OpenSSF Best Practices](https://img.shields.io/cii/level/16343?label=OpenSSF%20Best%20Practices)](https://www.bestpractices.dev/projects/16343)

A landing zone for OpenStack: a reference architecture, with deployable OpenTofu and Terraform code, for organising the projects of an organisation on an OpenStack cloud. Each tenant and each shared service has its own project. They meet on shared networks by role (planes), joined through a hub or provided by the cloud operator, and are published either behind a shared HTTPS entry point or directly on their own public address. Isolation rules are stated as a matrix and checked by a test you run on your own deployment.

The reference deploys two types of tenant, each in its own project:

- **Virtual machines** behind their own load balancer, spread over hosts and availability zones. The certificates of their domains are obtained and renewed at the tenant's entry, and every inbound and outbound flow is declared and filtered.
- **Kubernetes clusters** created with Cluster API. The cloud controller manager drives their OpenStack load balancers, and applications are published through the Gateway API, with their certificates managed in the cluster.

Either type can be exposed directly on the Internet, published behind the central entry point, or kept private, with no exposure at all. The internal services plane belongs to the shared services, such as a Kubernetes cluster for internal services that admits declared consumers only. The reference needs a member role only, on a public, sovereign or private cloud.

![Architecture overview: shared services and tenants, each in its own project, meet on shared networks (planes); arrows show who opens each connection](docs/images/architecture-overview.png)

**Read:** [why](#why) and the [design areas](#design-areas) to evaluate it, [getting started](#getting-started) to deploy it, the [ADRs](docs/adr/README.md) for the reasoning.

## Contents

- [Why](#why) · [Terms](#terms) · [Design areas](#design-areas) · [Principles](#principles) · [How it fits together](#how-it-fits-together)
- [What the repository contains](#what-the-repository-contains) · [Built on terraform-openstack-tenant](#built-on-terraform-openstack-tenant) · [Scope](#scope)
- [Getting started](#getting-started) · [Day-to-day](#day-to-day) · [Before production](#before-production) · [Documentation](#documentation)
- [Status](#status) · [Requirements](#requirements) · [Contributing](#contributing) · [Security](#security) · [License](#license)

## Why

Public clouds call it a *landing zone*: the structure an organisation puts in place before running workloads — how resources are divided, how networks connect, how services are exposed, observed and administered, and how isolation is enforced. AWS, Azure and Google Cloud provide one, and the design areas they cover are well established.

OpenStack provides the building blocks — projects, Neutron networks and routers, Octavia, Designate, Keystone — and leaves their assembly to each organisation:

- projects reach each other through networks shared by RBAC and routers, with no managed equivalent of a transit gateway or peering;
- each project publishes its own load balancers, with no entry shared between projects;
- no convention spans the projects of an organisation: names, address ranges, admission rules, and what one project must hand to another (its sources, its service address), usually copied by hand.

Each organisation assembles them its own way, often as a few shared networks and hand-written rules, and the isolation they give is rarely tested.

Some providers publish a landing zone for their own cloud, built on their account model and network services. For the other OpenStack clouds, public or private, and for teams that hold a member role only, this repository proposes that layer as a reference: decisions, stacks that pass what each needs through explicit contracts, and a tested scenario. Next to a provider's landing zone, it organises the projects inside; the provider's keeps accounts, identity and central inspection.

## Terms

| Term | Meaning |
|---|---|
| Tenant | A project running workloads, isolated from the other tenants |
| Shared service | A service run once for several tenants, in its own project; the entry point that publishes the tenants' domains is one |
| Plane | A shared network that connects tenants and shared services; any number, each with its own purpose. Each project joins it through its own router and, on each plane, either provides a service (role `shared`) or consumes (role `tenant`) |
| Operator plane | A plane provided by the cloud operator as an external network |
| Hub plane, hub project | A plane you build yourself, with a member role, as a network of a hub project shared with the other projects; the hub project holds the planes and a transit router, and runs nothing |

The other terms (service address, ingress, integration point, region, site, cloud operator, administrators): [glossary](docs/concepts/glossary.md).

## Design areas

The design areas of a landing zone, and the answer of this reference to each. The decisions are recorded in [ADRs](docs/adr/README.md); [Status](#status) gives the release that delivers each area.

| Design area | Question | Answer of this reference |
|---|---|---|
| Resource organisation | How are the projects organised? | One project per tenant, per shared service, and a hub project for the shared networks ([ADR-0003](docs/adr/0003-scope-and-boundary.md)) |
| Network topology and connectivity | How do isolated projects reach common networks and services? | Shared networks (*planes*), any number, provided by the cloud operator or built with a member role; each project provides or consumes on each plane, and routes follow from these roles. Several regions are joined by an encrypted overlay between their hubs ([ADR-0004](docs/adr/0004-planes-and-isolation.md), [ADR-0003](docs/adr/0003-scope-and-boundary.md) D2) |
| Network services | How do tenants resolve names, keep time, install packages and reach the Internet? | Resolvers and time from the cloud; internal names in Designate or as an output; package mirrors as an integration point; egress to the Internet only through a declared path; IPv4 until `v1.0`, then one address family per deployment ([network services](docs/concepts/architecture.md#network-services)) |
| Security and isolation | What keeps projects apart, and how is it proven? | Security groups at every target, a stated threat model, and an executable test of every flow, allowed and denied ([ADR-0004](docs/adr/0004-planes-and-isolation.md)) |
| Exposure | How are services published to the Internet? | One address per service; a shared entry point for many domains on few addresses, or an address per tenant; TLS stays with the tenant, which obtains its certificates by ACME DNS-01 ([ADR-0006](docs/adr/0006-exposure.md)) |
| Observability | How are isolated projects observed? | Metrics, logs and audit events pushed by each project to receivers of your choice; nothing connects into a project ([ADR-0007](docs/adr/0007-monitoring.md)) |
| Identity and access | Who administers what, from where? | One least-privilege credential per stack and project; bastions and APIs open to named administrator addresses only ([ADR-0005](docs/adr/0005-stacks-contracts-and-access.md)) |
| Resilience and continuity | What survives the loss of a host, a zone, a site? | Instances, Kubernetes nodes and volumes spread over hosts and the zones you give; a site per region with its own entry point, ready for a failover by DNS that you run; the architecture rebuilt from code and protected states; tenant data backed up through an integration point. The placement is tested, the failover is yours ([resilience](docs/concepts/architecture.md#resilience-and-continuity)) |
| Automation | How is it all described and changed? | Independent stacks, one state and one credential each, contracts passed as outputs, a tested procedure, a GitOps pipeline as an integration point ([ADR-0005](docs/adr/0005-stacks-contracts-and-access.md)) |
| Workload platforms | What runs in a project? | Virtual machines, or Kubernetes created with Cluster API, both in the same isolation model. The reference owns what the landing zone requires of the cluster lifecycle; upgrades and scaling are Cluster API's ([ADR-0003](docs/adr/0003-scope-and-boundary.md) D3, [ADR-0002](docs/adr/0002-platform-kubernetes.md), [ADR-0009](docs/adr/0009-kubernetes-lifecycle.md)) |
| Governance, identity federation, cost | Quotas, single sign-on, budgets | Level 1, not in this repository: projects, quotas and roles through [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-cloud-baseline) on a private cloud, or the provider's IAM on a public one; single sign-on and budgets are yours ([scope](#scope)) |

## Principles

- **The project is the unit of isolation.** Every tenant and every shared service has its own credentials, quotas and networks.
- **Everything that crosses projects goes through a declared shared network.** Nothing is reached through an undeclared path; tenants never reach each other.
- **Isolation is enforced at each target and verified.** Routes are not a security boundary; security groups are, and a test probes every flow after each change.
- **Flows are initiated by the side that holds the route back.** Tenants expose one address per service and push what they send; nothing opens a way into a tenant for someone else's convenience.
- **The reference owns the architecture, not the tools.** Platform services (metrics, logs, internal services) plug into documented integration points with the tools you choose ([integration points](docs/reference/integration-points.md)).
- **Works with a member role.** Nothing requires administrator rights on the cloud, so it applies to public and sovereign clouds as well as private ones.

## How it fits together

The [overview](#openstack-multitenant-reference) at the top shows how the parts fit together. Arrows show who opens the connection: the entry point reaches the tenants' service addresses through the publication plane, the tenants push to the receivers and call the internal services through the other planes, and nothing on a plane opens a connection into a tenant. Each tenant joins only the planes it needs. The planes shown are those of the reference scenario; the [architecture](docs/concepts/architecture.md) details each part.

## What the repository contains

| Layer | Content | Use |
|---|---|---|
| Decisions | [ADRs](docs/adr/README.md), [trade-offs](docs/concepts/trade-offs.md), [who it is for](docs/concepts/audiences.md) | read, challenge, adapt |
| Building blocks | [`stacks/shared/planes`](stacks/shared/planes/README.md) (any planes, a role per plane, provided or built), [`modules/`](modules) (joining a plane, admission rules, bastion, metrics agent, ACME client, [Kubernetes cluster](modules/kubernetes-cluster/README.md)) | use as they are |
| Reference scenario | Three planes (publication, observability, internal services); a shared entry point; a metrics receiver and an internal service, test fixtures that stand in for yours; the [shared cluster](stacks/shared/kubernetes/README.md) (a Kubernetes cluster for shared services), whose services are demonstrated, not operated; two tenant types: [`vm`](stacks/tenants/vm/README.md), as a web tenant behind the entry point and a private tenant with neither exposure nor egress, and [`kubernetes`](stacks/tenants/kubernetes/README.md); the [isolation test](docs/guides/check-isolation.md) | deploy as a working example, then adapt or extend |

The scenario is one instance of the design, chosen to exercise the design areas. Its three planes, by purpose and by name in the code:

| Purpose | Key in `shared/planes` |
|---|---|
| Publication: the entry point reaches the tenants' service addresses | `publication` |
| Observability: every project pushes its metrics, logs and audit events | `observability` |
| Internal services offered to some tenants | `internal` |

Another plane or shared service is declared in `shared/planes`; the stacks that join it name it in their call to [`modules/plane-attachment`](modules/plane-attachment/README.md). Each stack has its own state and `clouds.yaml` entry ([architecture](docs/concepts/architecture.md)).

| Stack | Role in the scenario |
|---|---|
| [`stacks/shared/planes`](stacks/shared/planes/README.md) | The planes: adopts the cloud operator's external networks, or builds shared networks in the hub project with a transit router; derives the routes of every project |
| [`stacks/shared/entry-point`](stacks/shared/entry-point/README.md) | A load balancer and two proxies routing by TLS server name to the tenants' service addresses, without decrypting |
| [`stacks/shared/kubernetes`](stacks/shared/kubernetes/README.md) | The shared cluster, not published: an internal ingress and layer 4 services, admitted to their consumers only |
| [`stacks/tenants/vm`](stacks/tenants/vm/README.md) | Virtual machines, their exposure and egress declared: behind a load balancer, published through the entry point or with their own address; or private, with neither exposure nor egress |
| [`stacks/tenants/kubernetes`](stacks/tenants/kubernetes/README.md) | The published cluster, a Kubernetes cluster created with Cluster API ([node image](images/kubernetes-node/README.md)) |

## Built on terraform-openstack-tenant

Every stack describes its project with the [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) module, and inherits its properties:

- **One model for every project.** Tenants, shared services and the hub are described the same way — networks, routers, security groups, instances, load balancers, DNS — so the architecture is a composition, not a collection of scripts.
- **Composition across stacks and teams.** Objects owned by another stack are passed in as values (*adoption*), never looked up behind the caller's back; outputs follow a provider-neutral contract that upper layers (Kubernetes, configuration management, inventories) consume.
- **Safe day-to-day changes.** Every resource key comes from the input: one plan, no `-target`, and an empty plan after apply. Lifecycle behaviours are fixed and documented, and inputs are validated before anything is created.
- **Least privilege by construction.** A member role on the project is enough; the module reads no other project and creates no unnecessary secret.
- **No imposed tooling.** No backend, secret store or CI tool; OpenTofu and Terraform on equal footing; tested on a real cloud before every release.
- **The same model down to the foundation.** The [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-cloud-baseline) module, in its own repository, describes what needs the administrator role — projects, quotas, users, shared networks — with the same model, for private clouds.

## Scope

The reference owns how the projects are organised, connected, exposed and kept available. The cloud foundation below, the platform services and the workloads above, and what joins from outside connect to it at a stated place ([ADR-0003](docs/adr/0003-scope-and-boundary.md)).

| Layer | What it does | Who owns it | Here |
|---|---|---|---|
| Deploying OpenStack | installs, upgrades and runs the cloud's services (Nova, Neutron, Octavia…) | the cloud's operator, with a deployment tool | no |
| 1. Cloud foundation | what the projects get from the cloud: projects, quotas, roles, flavors, images, external networks | the cloud's operator, or the customer through the provider's IAM | no: consumed |
| **2. Multi-tenant architecture (the landing zone)** | how the projects are organised, connected, exposed and kept available | the platform architect | **yes** |
| 3. Platform services | metrics, logs, audit, backups, secrets, with their own tools | the platform or operations team | no: connected at integration points |
| 4. Workloads | what the tenants run | each tenant | no |

![What the reference owns (level 2, multi-tenant architecture) and what connects to it: the cloud foundation below, platform services and workloads above through integration points, on-premises networks, an inspection firewall, a WAF and other clouds or regions on the sides](docs/images/scope.png)

For each need outside it, where it connects: [who it is for](docs/concepts/audiences.md#outside-the-reference-compatible-with-it). For a single project of instances, use [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) and its examples directly. A Kubernetes cluster comes with this reference ([`stacks/tenants/kubernetes`](stacks/tenants/kubernetes/README.md), built on [`modules/kubernetes-cluster`](modules/kubernetes-cluster/README.md)), published through the entry point or directly.

## Getting started

- [Getting started](docs/getting-started/README.md): one path for every cloud; only the configuration of the planes differs. About 20 minutes with the entry point and a `vm` tenant.

Two profiles ([ADR-0014](docs/adr/0014-profiles.md)) are tested by the maintainers. They are the same stacks; only a few inputs differ, set in each stack's `terraform.tfvars`:

| Profile | For | Inputs that differ | Tested by |
|---|---|---|---|
| `private-cloud` | a cloud you or your operator run | planes of the operator or of a hub project ([`examples/planes`](examples/planes/README.md)); the defaults otherwise; `internal_zone` of the shared cluster when the cloud has Designate | [`scenarios/private-cloud.toml`](tests/campaign/scenarios/private-cloud.toml), both plane modes |
| `public-cloud` | a public cloud, with the member role only | hub planes ([`hub.tfvars.example`](examples/planes/hub.tfvars.example)); `bastion_placement = "stack-network"` in `entry-point` and `vm`: the bastion on the stack's network, its floating IP on the egress router, 4 routers per project at most; security groups allowed in each project (some providers require a request) | [`scenarios/public-cloud.toml`](tests/campaign/scenarios/public-cloud.toml) |

<details>
<summary>Output of a real run: HTTPS through the entry point, then the isolation test (interface mode, one project per stack, 2026-11-23)</summary>

```console
$ for d in site-a.example.org site-b.example.org apps.published.example.org; do
    for i in $(seq 12); do curl -s --cacert root.pem --resolve $d:443:$LB https://$d/ | grep -E "client=|X-Real-Ip"; done | sort | uniq -c; done
     12 host=site-a.example.org  client=198.51.100.100
     12 host=site-b.example.org  client=198.51.100.100
     12 X-Real-Ip: 198.51.100.100
$ python3 tests/isolation/check.py --receiver tests/fixtures/receiver --key ~/.ssh/id_ed25519 --acme tests/fixtures/acme \
    --web-workspace web --private-workspace private --published-kubeconfig published.kubeconfig
from                   to                                                    port  expected actual  
test runner            entry point (public IP)                                443  open     open     ✅
test runner            entry point (public IP)                                 80  open     open     ✅
test runner            web service address 10.21.0.6                          443  closed   closed   ✅
edge t1-edge-1         web service address 10.21.0.6                          443  open     open     ✅
edge t1-edge-1         web t1-web-1 (private 10.21.0.16)                      443  closed   closed   ✅
private t1-private-1   web service address 10.21.0.6                          443  closed   closed   ✅
web t1-web-1           edge t1-edge-1 (private 10.20.0.194)                   443  closed   closed   ✅
edge t1-edge-1         receiver 10.34.0.4                                    9090  open     open     ✅
web t1-web-1           receiver 10.34.0.4                                    9090  open     open     ✅
private t1-private-1   receiver 10.34.0.4                                    9090  open     open     ✅
receiver               t1-edge-1 metrics (private 10.20.0.194)               9100  closed   closed   ✅
receiver               t1-web-1 metrics (private 10.21.0.16)                 9100  closed   closed   ✅
receiver               t1-private-1 metrics (private 10.22.0.245)            9100  closed   closed   ✅
edge t1-edge-1         receiver 10.34.0.4 (SSH)                                22  closed   closed   ✅
web t1-web-1           receiver 10.34.0.4 (SSH)                                22  closed   closed   ✅
private t1-private-1   receiver 10.34.0.4 (SSH)                                22  closed   closed   ✅
receiver               web service address 10.21.0.6                          443  closed   closed   ✅
receiver               edge t1-edge-1 (private 10.20.0.194)                   443  closed   closed   ✅
receiver               series pushed by edge                                    -  yes      yes      ✅
receiver               series pushed by web                                     -  yes      yes      ✅
receiver               series pushed by private                                 -  yes      yes      ✅
web t1-web-1           private t1-private-1 (private 10.22.0.245)              22  closed   closed   ✅
private t1-private-1   web t1-web-1 (private 10.21.0.16)                      443  closed   closed   ✅
private t1-private-1   Internet (192.0.2.101)                                     443  closed   closed   ✅
edge t1-edge-1         routed IPv6 (global address, default route)              -  none     none     ✅
web t1-web-1           routed IPv6 (global address, default route)              -  none     none     ✅
private t1-private-1   routed IPv6 (global address, default route)              -  none     none     ✅
receiver               routed IPv6 (global address, default route)              -  none     none     ✅
published Service      ingress on the stack address                             -  yes      yes      ✅
edge t1-edge-1         published ingress 10.24.0.10                           443  open     open     ✅
test runner            published ingress 10.24.0.10                           443  closed   closed   ✅
web t1-web-1           published ingress 10.24.0.10                           443  closed   closed   ✅
private t1-private-1   published ingress 10.24.0.10                           443  closed   closed   ✅
published pod          receiver 10.34.0.4                                    9090  open     open     ✅
receiver               series pushed by published                               -  yes      yes      ✅
test runner (administrator) published Kubernetes API 192.0.2.102                  6443  open     open     ✅
published pod          edge bastion 192.0.2.103 (SSH)                          22  closed   closed   ✅
published pod          web bastion 192.0.2.104 (SSH)                           22  closed   closed   ✅
published pod          private bastion 192.0.2.105 (SSH)                       22  closed   closed   ✅
published pod          internal service 192.0.2.106                         8080  open     open     ✅
web t1-web-1           internal service 192.0.2.106                         8080  closed   closed   ✅
private t1-private-1   internal service 192.0.2.106                         8080  closed   closed   ✅
edge t1-edge-1         internal service 192.0.2.106                         8080  closed   closed   ✅
receiver               internal service 192.0.2.106                         8080  closed   closed   ✅
receiver               published ingress 10.24.0.10                           443  closed   closed   ✅
test runner            published certificate of apps.published.example.org   443  valid    valid    ✅
test runner            web certificate of site-a.example.org   443  valid    valid    ✅
test runner            web certificate of site-b.example.org   443  valid    valid    ✅
web t1-web-1           TSIG update _acme-challenge.site-a.example.org    53  accepted accepted ✅
web t1-web-1           TSIG update _acme-challenge.apps.published.example.org    53  refused  refused  ✅
web t1-web-1           TSIG update _acme-challenge.services.example.org    53  refused  refused  ✅

51/51 rows as expected
```

</details>

## Day-to-day

| Task | Guide |
|---|---|
| Bring existing projects in | [existing-projects](docs/guides/existing-projects.md) |
| Add a tenant | [add-a-tenant](docs/guides/add-a-tenant.md) |
| Publish a domain | [publish-a-domain](docs/guides/publish-a-domain.md) |
| Open a service after qualification | [open-a-service](docs/guides/open-a-service.md) |
| Give a tenant trusted certificates | [certificates](docs/guides/certificates.md) |
| Check the isolation after a change | [check-isolation](docs/guides/check-isolation.md) |
| Discover the published cluster | [kubernetes-tour](docs/guides/kubernetes-tour.md) |
| Upgrade a Kubernetes cluster, rotate its credential | [kubernetes-lifecycle](docs/guides/kubernetes-lifecycle.md) |
| Rebuild after a loss | [rebuild](docs/guides/rebuild.md) |
| Tear down | [teardown](docs/guides/teardown.md) |

## Before production

This is a reference, not an operated platform. What stays yours:

- **the tools** behind the integration points: metrics, logs and audit receivers, backup and secret stores;
- **identity**: single sign-on for the administration access (your identity provider, or the provider's IAM);
- **certificates**: the tenants run in demonstration mode (self-signed) until `certificates` is set ([guide](docs/guides/certificates.md));
- **capacity**: quotas per project ([sizing](docs/reference/sizing-and-limits.md)) and room per compute host — the entry point instances are in anti-affinity, and a replacement needs room on another host;
- **the trade-offs**: read [them](docs/concepts/trade-offs.md) against your own constraints.

## Documentation

| | |
|---|---|
| **Getting started** | [Getting started](docs/getting-started/README.md) · [Profiles](#getting-started) · [Where the planes come from](examples/planes/README.md) |
| **Guides** | [Existing projects](docs/guides/existing-projects.md) · [Add a tenant](docs/guides/add-a-tenant.md) · [Publish a domain](docs/guides/publish-a-domain.md) · [Open a service](docs/guides/open-a-service.md) · [Certificates](docs/guides/certificates.md) · [Check the isolation](docs/guides/check-isolation.md) · [Kubernetes tour](docs/guides/kubernetes-tour.md) · [Kubernetes lifecycle](docs/guides/kubernetes-lifecycle.md) · [Rebuild](docs/guides/rebuild.md) · [Tear down](docs/guides/teardown.md) |
| **Reference** | [Integration points](docs/reference/integration-points.md) · [Planes contract](docs/reference/planes-contract.md) · [Isolation matrix](docs/reference/isolation-matrix.md) · [Test procedure](docs/reference/test-procedure.md) · [Sizing and limits](docs/reference/sizing-and-limits.md) · [Domain publication script](scripts/publish-domains.sh) · stack READMEs above |
| **Concepts** | [Who it is for](docs/concepts/audiences.md) · [Architecture](docs/concepts/architecture.md) · [Security model](docs/concepts/security.md) · [How a tenant joins a plane](docs/concepts/plane-attachment.md) · [Connecting two tenants](docs/concepts/connecting-tenants.md) · [Trade-offs](docs/concepts/trade-offs.md) · [Landscape](docs/concepts/landscape.md) · [Test results](docs/concepts/test-results.md) · [ADRs](docs/adr/README.md) · [Specs](docs/specs/README.md) |
| **Tests** | [Isolation test](tests/isolation/README.md) · fixtures: [metrics receiver](tests/fixtures/receiver/README.md), [internal service](tests/fixtures/internal-service/README.md), [ACME authority](tests/fixtures/acme/README.md) · [node image boot check](tests/integration/node-image/README.md) |
| **Project** | [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Support](SUPPORT.md) · [Security](SECURITY.md) |

## Status

The design above is the target of `v1.0`. Each release delivers part of it, tested end to end on a real cloud ([test results](docs/concepts/test-results.md)); the order of the next ones may change.

| Release | Design areas delivered | |
|---|---|---|
| `v0.1` | First entry point (SNI, TLS passthrough), VM and isolated tenants, executable isolation test; operator planes only | released |
| `v0.2` | Kubernetes tenant with Cluster API, self-managed, with its node image | released |
| `v0.3` | Resource organisation; planes provided by the cloud operator or built with a member role; isolation and its test; exposure by service addresses, domains published without interruption; the integration point for metrics (push contract, the receiver is yours); identity and access; automation; VM and Kubernetes tenants | released |
| `v0.4` | Certificates of the tenants ([ADR-0008](docs/adr/0008-tenant-certificates.md)); a Kubernetes cluster for shared services ([ADR-0010](docs/adr/0010-kubernetes-shared-services.md)); the Kubernetes lifecycle the landing zone requires ([ADR-0009](docs/adr/0009-kubernetes-lifecycle.md)); direct exposure of both tenant types, without the entry point | released |
| **`v0.5`** | Availability zones: placement over the zones and requirements on the cloud; recovery of the architecture ([ADR-0012](docs/adr/0012-resilience-scope.md)); environments ([ADR-0011](docs/adr/0011-environments.md)); plane routes on a transit router, so that an exposure change or a plane joined later reaches the existing load balancers ([ADR-0013](docs/adr/0013-plane-routes-on-a-transit-router.md)); in `v0.5.1`, the test campaign by profile, in Python ([ADR-0014](docs/adr/0014-profiles.md), [`tests/campaign`](tests/campaign/README.md)) | released |
| `v0.6` | Network services and the edge, by level ([ADR-0016](docs/adr/0016-network-services-and-edge-by-level.md)): egress declared per tenant, with an optional shared egress; resolvers and time from the cloud, checked by the isolation test; internal names in Designate or as an output; package mirrors as an integration point; the routes of the entry point as a reviewed input; a test that tenants have no routed IPv6 ([ADR-0015](docs/adr/0015-ipv6.md)); upgrades between releases: the release campaign tested from the previous release, the clusters updated through their API ([ADR-0017](docs/adr/0017-upgrades-between-releases.md)) | |
| `v0.7` | Routed operator planes: address scopes and subnet pools from [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-cloud-baseline), tested on its DevStack bench | |
| `v0.8` | Integration points, contracts only (the tools are yours): logs and audit; backups of tenant data; secrets; a GitOps pipeline, with continuous verification (the isolation test and a drift plan, run on a schedule) | |
| `v0.9` | Several regions: a site per region, hubs joined by an encrypted overlay; ready for a failover of the entry point by DNS, which you run and rehearse | |
| `v1.0` | The whole design, tested on a private OpenStack cloud (all of it) and on a public one (what differs between them, [profiles](#getting-started)); stable interfaces | |
| after `v1.0` | IPv6, as one address family per deployment ([ADR-0015](docs/adr/0015-ipv6.md)); integrations of platform tools (level 3) in a separate repository, when users ask for them | |

The current state is tested on a private OpenStack 2025.1 cloud (OpenStack-Ansible, OVN, Octavia amphora, Designate) with OpenTofu 1.13.2 and provider 3.4.0, each stack in its own project, from empty projects, with both kinds of planes: apply, empty plan after apply, HTTPS end to end, a domain published under load without a lost request, certificates from an internal ACME authority on both tenant types, the shared cluster with its consumers, credential rotation and Kubernetes upgrade with volumes kept, direct exposure of both tenant types and back behind the entry point, isolation test (45/45 with the shared cluster, 47/47 with the published cluster, on both kinds of planes), destroy without leftover. The test cloud has one availability zone. Let's Encrypt takes the same path with another directory; it is not tested by the maintainers. CI validates every configuration on OpenTofu and Terraform, lowest supported and latest.

## Requirements

| Component | Requirement |
|---|---|
| OpenTofu or Terraform | >= 1.9 |
| Provider `terraform-provider-openstack/openstack` | `~> 3.2` |
| Module | [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) `v0.1.6`, pinned in every stack |
| OpenStack | Keystone v3, Nova (metadata service), Glance, Octavia (amphora); Neutron with routers, and network sharing by RBAC for hub planes; Cinder for boot volumes and Designate for the public records and the ACME DNS-01 challenges, both optional |
| Credentials | One project per tenant and per shared service, plus the hub project for hub planes; project-scoped credentials (`member`, plus `load-balancer_member` if your Octavia policy requires it), one `clouds.yaml` entry per stack |
| Planes | Operator planes: the [planes contract](docs/reference/planes-contract.md) (names, ranges, MTUs, reserved ranges). Hub planes: built by [`stacks/shared/planes`](stacks/shared/planes/README.md) |

Quotas per project: [sizing](docs/reference/sizing-and-limits.md).

## Contributing

Contributions, and test reports from other clouds, are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the checks, the tests on a real cloud and the commit rules, and follow the [Code of Conduct](CODE_OF_CONDUCT.md). For questions, see [SUPPORT.md](SUPPORT.md).

## Security

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). Never attach state files, credentials or infrastructure details to issues or pull requests.

## License

Copyright © 2025-2026 Cypris Tech and contributors. Licensed under the [Apache License 2.0](LICENSE).

Maintained by [Gregory Gabrielian](https://github.com/CyprisTech) at [Cypris Tech](https://github.com/CyprisTech).
