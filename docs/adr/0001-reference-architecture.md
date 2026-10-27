# ADR-0001: Scope and structure of the reference architecture

- **Status:** Proposed
- **Date:** 2026-10-27
- **Deciders:** Gregory Gabrielian

## Context

[terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) (v0.1.0) describes one OpenStack tenant. It shows engineering quality, not how several tenants fit together in one cloud. This repository fills that gap: a complete multi-tenant architecture, with its design choices argued and its trade-offs stated.

Two audiences read it:

- **cloud consumers without admin rights** (public or sovereign OpenStack clouds), the primary audience of the module;
- **operators** who run their own cloud and decide what is shared between tenants.

Constraints:

- Everything runs on the released module; the repository adds no Terraform module of its own.
- No real identifiers: domains are `example.org`, addresses are documentation ranges, names are generic.
- The admin-level module (`cloud-baseline`) ships only in v0.2 of terraform-openstack-tenant.

The specification that goes with this ADR (diagrams, reachability matrix, layer 10 contract, sizing) is [docs/architecture.md](../architecture.md).

## Options considered

1. **Wait for cloud-baseline (v0.2) before writing any code.** The repository would be complete from the start, but it would be blocked by a whole release cycle, and the code would assume admin rights that the primary audience does not have.
2. **Start with layers 20 and 30, layer 10 provided by the operator.** The shared planes are described by a contract and adopted by name; cloud-baseline adds layer 10 later without changing layers 20 and 30.
3. **Kubernetes with a homemade kubeadm or cloud-init bootstrap.** Simple to show, but no lifecycle (upgrades, node replacement, certificate rotation); this is what operators move away from.
4. **Kubernetes with Cluster API Provider OpenStack (CAPO).** The community standard on OpenStack (kubernetes-sigs, also the base of the current Magnum drivers); declarative lifecycle; works with a project-scoped application credential, without admin rights.
5. **Central security group catalogue shared by RBAC as the default.** Central governance, but useless to a consumer with a single project and dependent on owning the shared objects.

Options 2 and 4 are chosen; options 3 and 5 are rejected as defaults (5 survives as an operator option, see D7).

## Decision

### D1 — Three layers, one state per stack

```text
stacks/
  10-shared-planes/      # operator layer: shared planes, optional catalogue (v0.2, cloud-baseline)
  20-public-edge/        # project "edge"
  30-tenants/
    web/
    platform/
    isolated/
```

- Until cloud-baseline v0.2, layer 10 is **provided by the operator**. [The layer 10 contract](../architecture.md#layer-10-contract) lists exactly what layers 20 and 30 expect.
- Stacks reference each other **by name through `existing`**, never through remote state. Each stack keeps its own state and stays independent of the state backend, as in the module.

### D2 — Shared network planes

The operator shares three planes: `intranet`, `monitoring` and `svc_public`. A tenant joins only the planes it needs, through dedicated routers; the routes to each plane are advertised by DHCP (`routers` and `advertise_routes` in the module), so instances need no static route.

### D3 — Single public entry point

- Octavia listens in **TCP on port 443** and forwards to a pool in **`PROXY`** protocol: two Traefik replicas on different hosts (anti-affinity).
- Traefik routes by **SNI with TLS passthrough**. TLS ends on the backends, which own their certificates.
- Port 80 only redirects to HTTPS.
- Health monitors are **TCP checks on port 443**, not PING: a PING proves the VM is up, not that Traefik answers.
- Traefik forwards the client address to the backends with **PROXY protocol v2**, only to backends configured to accept it.
- Traefik images are pinned to a version.

Consequences: no WAF, no L7 routing and no TLS termination at the load balancer; certificate management is the backends' job.

### D4 — Kubernetes with Cluster API Provider OpenStack

- Terraform (the module) prepares the `platform` project: network, plane attachments, security groups, application credential.
- CAPO creates the cluster on that network: **three control-plane nodes behind an Octavia load balancer**, plus workers.
- The node image is built with image-builder and uploaded as a private image of the project.
- The CAPO controllers run in a **disposable management cluster (kind)** on a bootstrap machine; they only call the OpenStack APIs. Nothing is installed in the cloud.
- The repository ships no Kubernetes tooling of its own and no alternative bootstrap.

### D5 — Demonstration scenario

A fictional organisation, `example.org`:

| Project | Planes | Purpose |
|---|---|---|
| `edge` | `svc_public`, `monitoring` | Public entry point (D3) |
| `web` | `svc_public`, `monitoring` | Two domains served by VMs spread across hosts, routed by SNI |
| `platform` | `svc_public`, `intranet`, `monitoring` | CAPO cluster; its ingress is published through the edge |
| `isolated` | `monitoring` | A workload with no public exposure and no path to other tenants |

### D6 — Executable reachability matrix

The expected flows between the internet, the planes and the tenants are written as a matrix ([docs/architecture.md](../architecture.md#reachability-matrix)) and checked by a test script after each deployment. The matrix is both the isolation documentation and the acceptance test.

### D7 — Security groups and DNS

- **Each tenant declares its own security groups** with the module. This works on any cloud, including with a single project.
- A **central security group catalogue shared by RBAC is an operator option of layer 10**, delivered with cloud-baseline (v0.2). The choice between central governance and tenant autonomy is discussed in the trade-offs.
- Each tenant has its own DNS zone, created for the project, or records in a shared zone.

## Consequences

- The repository can start right after module v0.1.0; layer 10 code comes with module v0.2.0.
- Layers 20 and 30 must not depend on anything outside the layer 10 contract.
- Testing needs a dedicated project large enough for the whole scenario (about 11 instances) and write access for the CAPO controllers in that project.
- A bootstrap machine with Docker is needed to run the CAPO management cluster.
- Trade-offs to document in `docs/trade-offs.md`:
  - Octavia topology: single amphora or active/standby, chosen through the load balancer flavor;
  - failover between sites;
  - limits of SNI passthrough at the load balancer;
  - security group sharing and isolation on `svc_public`;
  - central catalogue against tenant-owned security groups;
  - layer 10 provided by the operator until v0.2;
  - integration test results of the module.

## Open points

- Octavia flavor (amphora topology) used in the scenario.
- CAPO and Kubernetes versions to pin.
