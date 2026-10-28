# ADR-0002: The `platform` tenant — Kubernetes with Cluster API

- **Status:** Accepted
- **Date:** 2026-10-27
- **Deciders:** Gregory Gabrielian
- **Refines:** ADR-0001, D4 (the management cluster becomes the workload cluster itself; Terraform no longer handles the cluster credential)

## Context

ADR-0001 (D4) chose Cluster API Provider OpenStack (CAPO) for Kubernetes and left the details open. The `platform` tenant must fit the rules of v0.1.0:

- Terraform (the module) prepares the infrastructure of the project; another tool manages the cluster lifecycle.
- Publishing on a plane is a floating IP of that plane (D2): backends on `svc_public`, metrics on `monitoring`.
- Everything the architecture claims about isolation is proven by the reachability matrix (D6).
- No admin role: the cluster runs with a credential scoped to its project.

The tests of v0.1.0 also showed two facts this design must respect: a tenant joining a plane reaches it through source NAT, so **an address of a plane's range identifies no one**; and the tenant MTU is smaller than the default, so **every overlay inside the tenant must account for it**.

## Options considered

1. **API endpoint**: a floating IP on the administration network, or access through a bastion only. The floating IP serves operators and deployment pipelines without an SSH hop; restricted to the administration sources, it exposes nothing more than a bastion does.
2. **Management cluster**: a separate, long-lived management cluster, or a self-managed workload cluster (`clusterctl move` after creation). A separate cluster is one more thing to run and back up; self-managed is the common pattern for a single cluster.
3. **Pod network**: Cilium or Calico. Both are mature; Cilium brings eBPF datapath, network policies at layers 3 to 7 and flow visibility (Hubble).
4. **Ingress**: Traefik with the Gateway API, Envoy Gateway, or ingress-nginx. ingress-nginx is retired; Traefik keeps one proxy technology across the architecture and supports PROXY protocol and the Gateway API.
5. **Monitoring**: the collector federates an in-cluster Prometheus through a load balancer on the monitoring plane, or the cluster pushes with `remote_write`. Federation keeps the collector in control (pull, as for every other tenant) and needs one exposure point for the whole cluster; CAPO cannot give each node a floating IP of the monitoring plane.
6. **Administration and intranet**: one network carrying both roles, or two networks. See D6.

## Decision

### D1 — Responsibilities

| Layer | Tool | Creates |
|---|---|---|
| Infrastructure | Terraform (module), stack `30-tenants/platform` | cluster network (`network_mtu`), routers to the egress network, `svc_public`, `monitoring` and `intranet` with DHCP routes, server groups, bootstrap instance (it is also the administration access point of the cluster) |
| Node image | image-builder, OpenStack builder (Packer) | private image of the project, built in the project itself |
| Cluster | Cluster API with CAPO, kubeadm | control plane and workers, API load balancer |
| Cluster add-ons | Cluster API Add-on Provider Helm (CAAPH) | OpenStack cloud controller manager, Cinder CSI, Cilium, Traefik, Prometheus, metrics-server, kubelet-csr-approver |

CAPO uses the network prepared by Terraform and creates no network or router. Its security groups (control plane, workers) are managed by CAPO.

**Credentials of the cluster.** CAPO, the cloud controller manager and Cinder CSI use an application credential dedicated to the cluster, restricted, with the `member` and `load-balancer_member` roles of the project only. The operator creates it and copies it to the bootstrap instance; Terraform never handles it. Creating it with Terraform was considered and rejected:

- the secret would be stored in the Terraform state, whose backend this architecture leaves to the user, and in the instance metadata if passed through cloud-init;
- Keystone forbids a restricted application credential to create another one, so Terraform would need a password or an unrestricted application credential, which can create further credentials and outlive any revocation of the operator's access.

### D2 — Cluster definition

- A **ClusterClass** describes the cluster shape; a short `Cluster` object instantiates it. Upgrades change the Kubernetes version of the `Cluster`, and Cluster API rolls the machines.
- **Three control-plane nodes** behind an Octavia load balancer created by CAPO, and one machine deployment of workers, each group spread across hosts (server groups with **soft** anti-affinity: the cluster still starts when the cloud has fewer hosts than machines).
- Versions of Cluster API, CAPO, CAAPH, Kubernetes and every add-on are pinned in the repository.
- Cluster API templates are immutable: their names carry a revision derived from their content, so that a change creates new templates and Cluster API replaces the machines one at a time.
- Machines are remediated by MachineHealthCheck (a node not Ready for 5 minutes is replaced; at most one worker at a time), and control-plane machines are replaced 21 days before their certificates expire.
- Kubelet serving certificates are signed by the cluster CA and approved by kubelet-csr-approver for this cluster's nodes only, so that metrics-server verifies the kubelets.

### D3 — Bootstrap and self-management

1. A bootstrap instance (created by the stack) runs kind and `clusterctl init` with CAPO and CAAPH.
2. The workload cluster is created from the bootstrap.
3. `clusterctl move` transfers the Cluster API objects into the workload cluster, which then manages itself.
4. The bootstrap instance may then be removed (`bootstrap = false`). It is recreated for teardown, or to repair a cluster that can no longer manage itself: Cluster API is moved back to a kind cluster on it.

While it manages the cluster, the bootstrap instance reaches the API through its own floating IP: its address is admitted on the API load balancer until the move, and again during teardown (D5).

Day-two operations (upgrades, scaling, machine replacement) run against the workload cluster. Teardown deletes the `Cluster` first, waits for the servers and load balancers to disappear, then destroys the stack.

### D4 — Networking inside the cluster

- **Cilium** with VXLAN encapsulation and an **explicit MTU**: the cluster network MTU minus the encapsulation overhead (50 bytes for VXLAN). With the 1362-byte tenant MTU of the test cloud, pods use 1312.
- Cilium enforces Kubernetes and Cilium network policies. This reference deploys none by default: isolation between tenants is enforced by the cloud (projects, routers, security groups, D8); policies inside the cluster are left to its users.

### D5 — Exposure

| Purpose | How | Admitted sources |
|---|---|---|
| Applications | Traefik with the Gateway API, behind a `LoadBalancer` service: an Octavia load balancer whose VIP gets a **floating IP of `svc_public`**. TCP listeners **without** PROXY on this load balancer: the entry point's PROXY v2 header passes through, so exactly one header reaches Traefik. `externalTrafficPolicy: Local` keeps the load balancer as the peer Traefik trusts; two Traefik replicas on two nodes | the entry point's addresses on `svc_public` only |
| Metrics | Prometheus in the cluster, behind a `LoadBalancer` service whose VIP gets a **floating IP of `monitoring`**; the collector federates it. The address is read from the Service (no DNS record is written for it yet) | the collector's addresses only |
| Kubernetes API | the CAPO load balancer with a **floating IP of the administration network**. The admitted sources are a variable of the `Cluster`, since templates are immutable and the list changes | the administration sources; the bootstrap instance while it manages the cluster; the cluster's own addresses (added by CAPO) |

The entry point routes the platform's domains to the ingress floating IP by SNI, like the `web` backends: routes are generated from the stack outputs (ADR-0001, D9).

### D6 — Administration and intranet are two roles

| Role | Carries | Who reaches it |
|---|---|---|
| Administration | SSH to bastions, Kubernetes API | operators only |
| Intranet | internal services consumed by tenants (registry, database, directory) | the tenants that need them, such as `platform` |

A tenant joining the intranet gets addresses of its range through source NAT. If administration endpoints admitted the whole intranet range, any workload of that tenant could reach the bastions and APIs of every tenant.

- **Recommended:** two networks, administration and intranet.
- **Accepted with one network:** the administration endpoints (bastion SSH, Kubernetes API) admit **specific operator addresses**, never the range of the network.
- The stacks already take the two roles as separate inputs (`bastion.external_network` for the VM stacks, `admin_network` for the platform, and the `intranet` plane), so moving from one network to two is a change of configuration.

The reference test cloud has one network for both roles; the tests use restricted administration sources and prove the separation in the matrix.

### D7 — The intranet flow

`platform` consumes an internal service on the intranet. For the tests, a demonstration service is published on the intranet; the matrix checks that `platform` reaches it and that `web` and `isolated` do not.

### D8 — Reachability matrix, new rows

| From | To | Expected |
|---|---|---|
| entry point | platform ingress, 443 | allowed |
| `web`, `isolated` | platform ingress | denied |
| collector | platform Prometheus federation | allowed |
| `web`, `isolated`, entry point | platform Prometheus | denied |
| operators | Kubernetes API, 6443 | allowed |
| `platform` | bastions (SSH), Kubernetes API of any tenant | denied |
| `platform` | intranet demonstration service | allowed |
| `web`, `isolated` | intranet demonstration service | denied |

## Consequences

- One more state per stack and one more lifecycle: Terraform for the infrastructure, Cluster API objects for the cluster. The repository documents the order of operations and the teardown.
- Two images to keep current: the node image (rebuilt with image-builder) and the add-on chart versions.
- The test cloud needs, for the duration of a test: 3 control-plane nodes and 2 workers (2 vCPU, 4 GiB each), a bootstrap instance and a temporary Packer build instance, 3 Octavia load balancers (API, ingress, metrics) and 3 more floating IPs.
- The administration role must be configured with specific sources in every stack; the layer 10 contract lists them.
- The first deployment revealed nine defects, all fixed (cloud API names, private CA, MTU of kind, API sources, DNS of the cloud controller manager, timing of the move, ORC image after the move, Helm release names, double PROXY header): see [testing.md](../testing.md). They are the practical cost of this design on a private cloud.
