# openstack-multitenant-reference

[![CI](https://github.com/CyprisTech/openstack-multitenant-reference/actions/workflows/ci.yml/badge.svg)](https://github.com/CyprisTech/openstack-multitenant-reference/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/CyprisTech/openstack-multitenant-reference?sort=semver)](https://github.com/CyprisTech/openstack-multitenant-reference/releases)
[![OpenTofu >= 1.9](https://img.shields.io/badge/OpenTofu-%3E%3D1.9-ffda18?logo=opentofu)](https://opentofu.org)
[![Terraform >= 1.9](https://img.shields.io/badge/Terraform-%3E%3D1.9-844fba?logo=terraform)](https://www.terraform.io)

A reference architecture for several tenants sharing one OpenStack cloud, built on the [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) module, with its design choices argued, its trade-offs stated and its isolation checked by an executable test.

> [!NOTE]
> **First release, `v0.1.0`.** It delivers layers 20 and 30: the public entry point and the `web` and `isolated` tenants, with bastions and monitoring. The full scenario was tested on a private OpenStack 2025.1 cloud, and the executable reachability matrix passed **27/27** rows ([test report](docs/testing.md)). The Kubernetes `platform` tenant (Cluster API Provider OpenStack) is **planned, not delivered**: [docs/architecture.md](docs/architecture.md) specifies it, but no stack exists yet. Layer 10 (the shared planes) is provided by the operator through a [contract](docs/architecture.md#layer-10-contract); cloud-baseline will provide it with module `v0.2`.

## Table of contents

- [What it demonstrates](#what-it-demonstrates)
- [Architecture](#architecture)
- [Status](#status)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Documentation](#documentation)
- [Roadmap](#roadmap)
- [Related project](#related-project)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## What it demonstrates

- **Shared network planes** (`svc_public`, `monitoring`, `intranet`) that each tenant joins only as needed, through its own routers, with the routes advertised by DHCP.
- **A single public entry point for many domains**: Octavia in TCP mode in front of two Traefik instances on different hosts, routing by SNI without terminating TLS, client address preserved with the PROXY protocol end to end.
- **Publishing on a plane with a floating IP of that plane**: backends on `svc_public`, admitted from the entry point only; every instance exposed to the monitoring collector through a `monitoring` floating IP, discovered through DNS records.
- **Tenant isolation as a test**: the reachability matrix of the specification is a script that probes every flow from inside the tenants and fails on any difference.
- **No address written by hand**: the entry point's routes are generated from the outputs of the tenant stacks.

## Architecture

Three layers, one state per stack. Stacks find each other's objects by name, never through remote state, and each takes its own `clouds.yaml` entry, so the tenants can live in one project or in several.

| Layer | Stack | Content |
|---|---|---|
| 10 | provided by the operator ([contract](docs/architecture.md#layer-10-contract)) | Shared planes, public network, monitoring DNS zone, collector |
| 20 | [`stacks/20-public-edge`](stacks/20-public-edge/README.md) | Octavia (TCP 80 and 443, PROXY protocol, TCP health monitors), two Traefik instances in anti-affinity, routers to `svc_public` and `monitoring` |
| 30 | [`stacks/30-tenants/web`](stacks/30-tenants/web/README.md) | Two web instances in anti-affinity serving two domains, published on `svc_public`, HTTPS admitted from the entry point only |
| 30 | [`stacks/30-tenants/isolated`](stacks/30-tenants/isolated/README.md) | One workload whose only router joins the monitoring plane: no public address, no path to the other tenants or to the Internet |
| 30 | `stacks/30-tenants/platform` | Kubernetes with Cluster API Provider OpenStack — **planned** |

Every stack can add a bastion, with a floating IP on an administration network. The topology, the request flow through the entry point and the cluster creation sequence are drawn as Mermaid diagrams in [docs/architecture.md](docs/architecture.md); the decisions behind them are in [ADR-0001](docs/adr/0001-reference-architecture.md).

## Status

| Part | Status |
|---|---|
| ADR-0001, architecture specification, trade-offs | done |
| Stack 20 `public-edge` | delivered, tested |
| Stacks 30 `web` and `isolated`, bastions | delivered, tested |
| Monitoring through floating IPs and DNS discovery | delivered, tested |
| Executable reachability matrix and test collector | delivered; 27/27 rows on the test cloud |
| Stack 30 `platform` (Kubernetes, CAPO) | planned |
| Layer 10 as code (`stacks/10-shared-planes`, cloud-baseline) | planned, with module `v0.2` |
| Failover between sites | later |

Tested on a private OpenStack 2025.1 cloud (OpenStack-Ansible, Neutron with OVN, Octavia amphora, Designate) with OpenTofu 1.13.2 and provider 3.4.0: apply, empty plan after apply, HTTPS end to end, reachability matrix, destroy without leftover. CI validates every configuration on OpenTofu and Terraform, lowest supported version and latest. Results, and the defects the tests revealed, are in [docs/testing.md](docs/testing.md). Not yet tested on a public OpenStack cloud.

## Requirements

| Component | Requirement |
|---|---|
| OpenTofu or Terraform | >= 1.9 |
| Provider [`terraform-provider-openstack/openstack`](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest) | `~> 3.2` |
| Module | [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) `v0.1.2`, pinned by tag in every stack |
| OpenStack services | Keystone v3, Nova, Neutron (routers, floating IPs from several external networks on one port), Glance, Octavia; Cinder for boot volumes (optional); Designate for the monitoring and public DNS records (optional) |
| Credentials | Project-scoped, no admin role: for example an application credential with `member` (plus `load-balancer_member` if your Octavia policy requires it); one `clouds.yaml` entry per stack |
| Tools for the matrix | Python 3 (standard library), `ssh`, `jq` |

**Layer 10 contract.** The operator must provide, per site ([full list](docs/architecture.md#layer-10-contract)):

- the networks `svc_public` and `monitoring` (`intranet` for the planned `platform`), visible to the tenant projects, each with a subnet usable as a router gateway, and their CIDRs;
- a public network with floating IPs reachable from the Internet, and a default route to the Internet for package installation at first boot;
- the **MTU** of each plane and of the tenant overlay: set `network_mtu` to the smallest value. OVN routers do not send "fragmentation needed" by default, so a larger MTU silently drops large packets (the TLS handshake hangs);
- the address ranges reserved by the cloud, which tenant networks must avoid;
- a DNS zone shared with the projects for the monitoring records, and the collector's addresses (`monitoring.collector_cidrs`);
- an Octavia flavor (active/standby recommended for the entry point), an Ubuntu LTS image and flavors.

**Quotas.** Layers 20 and 30 of v0.1.0 need at least 5 instances, 9 vCPU, 9 GiB of RAM, 1 load balancer and 8 floating IPs (1 public, 2 `svc_public`, 5 `monitoring`), plus one small instance and one floating IP per bastion, and the test collector. The [sizing table](docs/architecture.md#sizing) gives the figures per project, `platform` included.

## Quick start

> [!WARNING]
> These steps create real resources (instances, an Octavia load balancer, floating IPs, DNS records). Use a dedicated project. Make sure no `OS_*` variable is set in the shell: the client would mix it with the `clouds.yaml` entry.

Each stack has a `terraform.tfvars.example` with fictional names and documentation address ranges: copy it to `terraform.tfvars` (git-ignored) and adapt it to your cloud. Use the same `site` in every stack. The commands use `tofu`; `terraform` works the same.

**1. Test collector** (optional, needed for the reachability matrix). Write `terraform.tfvars` as shown in [its README](tests/integration/collector/README.md), then:

```bash
cd tests/integration/collector
tofu init && tofu apply
tofu output -json collector_cidrs   # give it to every stack as monitoring.collector_cidrs
```

**2. Public entry point.** It must exist before the tenants: `web` reads the entry point's addresses on `svc_public` from its router.

```bash
cd stacks/20-public-edge
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

**3. Tenant `web`.**

```bash
cd stacks/30-tenants/web
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

**4. Routes.** Generate the entry point's routes from the `web` outputs, then replace the Traefik instances **one at a time**, so that the load balancer keeps a healthy member (`SITE` is the `site` of the stacks):

```bash
# in stacks/30-tenants/web
tofu output -json routes \
  | jq '{routes: .}' > ../../20-public-edge/routes.auto.tfvars.json   # git-ignored

# in stacks/20-public-edge
tofu apply -replace='module.edge.module.instance["SITE-edge-1"].openstack_compute_instance_v2.this'
# wait until the member is ONLINE again: openstack loadbalancer member list SITE-edge-https
tofu apply -replace='module.edge.module.instance["SITE-edge-2"].openstack_compute_instance_v2.this'
```

**5. Tenant `isolated`.**

```bash
cd stacks/30-tenants/isolated
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

**6. Reachability matrix.** With the three stacks applied with bastions and the collector applied ([prerequisites](tests/reachability/README.md#prerequisites)), from the repository root:

```bash
python3 tests/reachability/check.py --stacks stacks --collector tests/integration/collector \
  --user ops --key ~/.ssh/id_ed25519
```

It exits with status 1 if any row differs from the matrix. To remove everything, run `tofu destroy` in the reverse order: `isolated`, `web`, `20-public-edge`, collector.

## Documentation

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Topology, flows, reachability matrix, layer 10 contract, sites, sizing |
| [docs/trade-offs.md](docs/trade-offs.md) | What each choice costs and when the alternative is better |
| [docs/adr/](docs/adr/README.md) | Architecture decision records |
| [docs/testing.md](docs/testing.md) | Test environment, results and findings |
| [tests/reachability/](tests/reachability/README.md) | Executable reachability matrix |
| [tests/integration/collector/](tests/integration/collector/README.md), [tests/integration/dual-floating-ip/](tests/integration/dual-floating-ip/README.md) | Test collector; the test behind the monitoring design |
| Stack READMEs | [20-public-edge](stacks/20-public-edge/README.md), [30-tenants/web](stacks/30-tenants/web/README.md), [30-tenants/isolated](stacks/30-tenants/isolated/README.md): inputs, outputs, operations |

## Roadmap

| Release | Content | Status |
|---|---|---|
| **v0.1.0** | Layers 20 and 30 in one site (entry point, `web`, `isolated`), bastions, monitoring through floating IPs and DNS, reachability matrix; layer 10 provided by the operator; module `v0.1.2` | released |
| next | Stack 30 `platform`: Kubernetes with Cluster API Provider OpenStack, published through the entry point | planned |
| next | Results on a public OpenStack cloud | planned |
| v0.2 | Layer 10 as code (`stacks/10-shared-planes`) with cloud-baseline (terraform-openstack-tenant `v0.2`) | planned |
| later | Failover between sites: an edge per site, runbook, failover drill | planned |

## Related project

[terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant): the OpenTofu and Terraform modules every stack of this repository is built on. They describe one OpenStack tenant in a single declarative model; this repository shows how several tenants fit together in one cloud.

## Contributing

Contributions, and test reports from other clouds, are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the checks, the tests on a real cloud and the commit rules, and follow the [Code of Conduct](CODE_OF_CONDUCT.md). For questions, see [SUPPORT.md](SUPPORT.md).

## Security

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). Never attach state files, credentials or infrastructure details to issues or pull requests.

## License

Copyright © 2025-2026 Cypris Tech and contributors. Licensed under the [Apache License 2.0](LICENSE).

Maintained by [Gregory Gabrielian](https://github.com/CyprisTech) at [Cypris Tech](https://github.com/CyprisTech).
