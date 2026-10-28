# Architecture

This document is the living specification of the reference architecture. The decisions behind it are recorded in [ADR-0001](adr/0001-reference-architecture.md); when the two disagree, the ADR states the intent and this document must be fixed.

All names are fictional: the organisation is `example.org`, and address ranges are left to the layer 10 contract.

> [!NOTE]
> **Delivered in v0.1.0:** layers 20 and 30 for the projects `edge`, `web` and `isolated`, with bastions, monitoring and the reachability matrix. **Delivered after v0.1.0, tested, not yet released:** the `platform` project (Kubernetes with Cluster API Provider OpenStack), see [testing.md](testing.md).

## Topology

Four projects consume the planes shared by the operator. Each project joins only the planes it needs, through its own routers, with the routes advertised by DHCP; it is published on a plane with a floating IP of that plane, and administered through its own bastion.

```mermaid
flowchart LR
    U(["Internet clients"])
    OPS(["Operators"])

    subgraph L10["Layer 10 - provided by the operator"]
        direction TB
        PUB["public network"]
        SVC["svc_public plane"]
        MON["monitoring plane"]
        ADM["administration network"]
        COL["collector"]
        INT["intranet plane"]
    end

    subgraph EDGE["Project edge - layer 20"]
        LB["Octavia<br/>TCP 80/443, PROXY pools<br/>TCP health monitors"]
        T["Traefik x 2<br/>anti-affinity"]
        LB --> T
    end

    subgraph WEB["Project web - layer 30"]
        W["web x 2<br/>anti-affinity"]
    end

    subgraph ISO["Project isolated - layer 30"]
        J["workload"]
    end

    subgraph PLAT["Project platform - layer 30"]
        K["Kubernetes<br/>Cluster API"]
    end

    U -->|"TLS with SNI"| PUB --> LB
    T -->|"PROXY v2, router to svc_public"| SVC
    SVC -->|"floating IP of svc_public"| W
    COL --> MON
    MON -.->|"floating IP of monitoring"| T & W & J
    OPS --> ADM -.->|"bastion of each project"| EDGE & WEB & ISO
    K -.-> SVC & INT & MON

```

| Project | Layer | Planes | Content |
|---|---|---|---|
| `edge` | 20 | `svc_public`, `monitoring` | Octavia load balancer with a public floating IP, two Traefik VMs (anti-affinity) |
| `web` | 30 | `svc_public`, `monitoring` | Two VMs (anti-affinity) serving `site-a.example.org` and `site-b.example.org`, each with an address on `svc_public` |
| `platform` | 30 | `svc_public`, `intranet`, `monitoring` | Kubernetes cluster created by CAPO; ingress load balancer with an address on `svc_public` |
| `isolated` | 30 | `monitoring` | One workload, no public address, no route to other tenants |

Backends are published on `svc_public` with addresses from that plane. Every project on `svc_public` can therefore reach them at the network level: **security groups restrict them to the edge Traefik instances** (see the reachability matrix).

## Network topology of a tenant

Each tenant network has **one router per network it joins**. Only one of them is the default gateway; the others are reached through routes that DHCP pushes to the instances (`advertise_routes`). A tenant reaches a plane through its router, with **source NAT**: on the plane, every instance of the tenant appears as the router's gateway address. That address, not the instance address, is what security groups of other tenants admit.

```mermaid
flowchart LR
    subgraph T["Tenant network, e.g. platform 10.24.0.0/24 (MTU 1362)"]
        VM["instances<br/>default route: egress router<br/>DHCP routes: one per plane"]
        LB["Octavia VIPs<br/>(same subnet)"]
    end
    RE["router egress<br/>default gateway"]
    RS["router svc_public<br/>route: svc_public range"]
    RM["router monitoring<br/>route: monitoring range"]
    RI["router intranet<br/>route: intranet range"]
    VM --> RE --> PUB["egress network<br/>(Internet)"]
    VM --> RS --> SVC["svc_public plane"]
    VM --> RM --> MON["monitoring plane"]
    VM --> RI --> INT["intranet plane<br/>(administration in the tests)"]
    LB -.-> RS & RM & RI
```

| Tenant | Default gateway | Other routers | Published on |
|---|---|---|---|
| `edge` | public network | `svc_public`, `monitoring` | public floating IP of the load balancer |
| `web` | egress | `svc_public`, `monitoring` | floating IPs of `svc_public` (backends), of `monitoring` (metrics) |
| `isolated` | `monitoring` | — | floating IP of `monitoring` only |
| `platform` | egress | `svc_public`, `monitoring`, `intranet` | ingress and Prometheus load balancers (floating IPs of `svc_public` and `monitoring`), API (floating IP of the administration network) |
| bastions | administration network | — (second port on the tenant network, no routes) | floating IP of the administration network |

Three rules follow from this design, each learned from a test failure (see [testing.md](testing.md)):

- **MTU.** Tenant networks use the smallest MTU of the planes they join: OVN routers do not send "fragmentation needed", so a larger MTU drops large packets silently.
- **Sources.** An administration source is the address *as seen on the plane*, often a router's: read it on the target (`$SSH_CLIENT`), do not guess it.
- **Floating IPs on a non-default router.** They work because the plane's range is routed back through that router (DHCP route, also applied by Octavia amphorae).

## Ingress data path

The client address must reach the application; TLS is terminated by the tenant, never by the entry point. Exactly **one PROXY v2 header** travels end to end, written by the entry point.

```mermaid
sequenceDiagram
    participant C as Client
    participant E as Octavia (edge)<br/>TCP, PROXY pool
    participant T as Traefik (edge)
    participant R as router svc_public<br/>(edge, source NAT)
    participant O as Octavia (platform)<br/>TCP pool, no PROXY
    participant K as Traefik (platform)<br/>externalTrafficPolicy Local
    participant A as Application
    C->>E: TLS ClientHello (SNI apps.example.org)
    E->>T: PROXY v1/v2 (client) + TLS
    Note over T: reads PROXY and SNI, does not decrypt
    T->>R: PROXY v2 (client address) + TLS
    R->>O: same bytes, source = edge router address (admitted)
    O->>K: same bytes, source = amphora (trusted range)
    Note over K: reads PROXY v2: client address<br/>terminates TLS, Gateway API routing
    K->>A: HTTP, X-Real-Ip = client address
```

| Hop | Source seen | Admitted by |
|---|---|---|
| Client → edge load balancer | client | listener, public |
| Traefik (edge) → backend floating IP | gateway address of the edge `svc_public` router | security group (`web`) or `loadBalancerSourceRanges` (`platform`) |
| Platform load balancer → Traefik | amphora address, in the cluster network | Traefik `proxyProtocol.trustedIPs` |

Two settings keep the single header intact on `platform`: no `proxy-protocol` annotation on the Traefik Service (a second header breaks the TLS handshake), and `externalTrafficPolicy: Local` (otherwise kube-proxy replaces the amphora address with a node address, Traefik does not trust it and drops the client address).

## Administration paths

```mermaid
flowchart LR
    OPS(["Operators<br/>specific addresses"])
    subgraph ADM["Administration network"]
        B1["bastion edge"]
        B2["bastion web"]
        B3["bastion isolated"]
        API["Kubernetes API<br/>floating IP"]
        BS["bootstrap instance<br/>(temporary)"]
    end
    OPS -->|"SSH 22"| B1 & B2 & B3 & BS
    OPS -->|"6443"| API
    B1 -->|"second port"| E["edge instances"]
    B2 -->|"second port"| W["web instances"]
    B3 -->|"second port"| I["isolated instance"]
    BS -->|"6443, until clusterctl move"| API
    N["platform nodes<br/>(through their router)"] -->|"6443"| API
```

| Endpoint | Admitted | Not admitted |
|---|---|---|
| Bastions (SSH) | the operator addresses | every tenant, including `platform` (tested) |
| Kubernetes API | the operator addresses; the cluster's own addresses (added by CAPO); the bootstrap instance while it manages the cluster | anything else |

With one network for the administration and intranet roles (the test cloud), operator addresses must be single addresses, never the network range: tenants joining the intranet appear inside that range ([ADR-0002](adr/0002-platform-kubernetes.md), D6).

## Lifecycle

```mermaid
flowchart TB
    L10["Layer 10 (operator)<br/>planes, public and administration networks, DNS zone, collector"]
    S20["Stack 20: public edge<br/>state 20"]
    W["Stack 30 web<br/>state web"]
    I["Stack 30 isolated<br/>state isolated"]
    IMG["Node image<br/>(build network, state image)<br/>outlives the cluster"]
    P["Stack 30 platform<br/>state platform: network, routers, bootstrap"]
    CAPI["create-cluster.sh on the bootstrap<br/>kind → Cluster API → cluster → add-ons"]
    MOVE["clusterctl move<br/>the cluster manages itself<br/>(Cluster API state inside the cluster)"]
    R["Routes of stack 20<br/>(web backends, platform ingress)"]
    L10 --> S20 --> W & I
    L10 --> IMG --> P --> CAPI --> MOVE
    W & MOVE --> R
```

| Operation | Order |
|---|---|
| Deploy | layer 10 → 20 → 30 (`web`, `isolated`, image then `platform`) → routes of 20 |
| Change routes | apply 20, then replace the edge instances one at a time |
| Upgrade Kubernetes | new node image, then `spec.topology.version` of the Cluster |
| Tear down | `delete-cluster.sh` (Services, move back to kind, delete the Cluster), then destroy `platform`, the 30 stacks, 20; the node image is deleted separately |

## Public entry point

```mermaid
sequenceDiagram
    participant C as Client
    participant O as Octavia (edge)<br/>TCP listener 443
    participant T as Traefik (edge)<br/>2 replicas
    participant B as Backend (web VM<br/>or platform ingress)
    C->>O: TCP connect + TLS ClientHello (SNI site-a.example.org)
    O->>T: PROXY header (client address) + raw TLS bytes
    Note over T: reads the SNI only, TLS is not terminated
    T->>B: PROXY v2 (client address) + raw TLS bytes, through svc_public
    B-->>C: TLS handshake completes on the backend (backend certificate)
```

| Element | Setting |
|---|---|
| Octavia listener 443 | `TCP`, pool protocol `PROXY`, round robin, TCP health monitor on 443 |
| Octavia listener 80 | `TCP`, pool protocol `PROXY`; Traefik answers with a redirection to HTTPS |
| Traefik entry points | `proxyProtocol.trustedIPs` limited to the load balancer subnet |
| Traefik routers | TCP routers, `HostSNI` per domain, `tls.passthrough: true`, connection limit middleware |
| Traefik services | PROXY protocol v2 to backends that accept it |
| Traefik image | pinned version |

What the edge does not do: TLS termination, L7 routing, WAF. Each backend owns its certificates.

### Deployment of the edge instances

```mermaid
flowchart LR
    M["routes map<br/>domain to backend"] --> TF["Terraform<br/>edge stack"]
    O["outputs of the tenant stacks<br/>backend addresses"] --> TF
    TF -->|"cloud-init: systemd unit,<br/>pinned image, routes file"| V1["edge VM 1"]
    TF -->|"same, replaced after VM 1 is healthy"| V2["edge VM 2"]
```

| Aspect | Setting |
|---|---|
| Runtime | Traefik container started by a systemd unit, no orchestrator |
| Installation | cloud-init, rendered by the module's `cloudinit` sub-module |
| Routes | file provider; the file is generated by Terraform |
| Change of routes | new cloud-init, instances replaced one at a time |
| Dashboard | not exposed; metrics on the `monitoring` plane |

## Kubernetes cluster creation

The design is [ADR-0002](adr/0002-platform-kubernetes.md); the stack is [`stacks/30-tenants/platform`](../stacks/30-tenants/platform/README.md).

```mermaid
sequenceDiagram
    participant TF as Terraform (stack 30 platform)
    participant OS as OpenStack APIs
    participant B as Bootstrap instance<br/>kind + Cluster API + CAPO + CAAPH
    participant W as Workload cluster
    TF->>OS: network, routers to the planes, server groups, bootstrap instance
    Note over B: the operator copies the cluster credential (clouds.yaml)
    B->>OS: image-builder (OpenStack builder): private node image
    B->>OS: CAPO: API load balancer (floating IP on the administration network)
    B->>OS: 3 control-plane servers, then workers (anti-affinity)
    B->>W: CAAPH: cloud controller manager, Cinder CSI, Cilium, Traefik, Prometheus
    W->>OS: ingress load balancer (floating IP of svc_public), metrics load balancer (floating IP of monitoring)
    B->>W: clusterctl move: the cluster manages itself
    Note over TF,B: the bootstrap instance is destroyed
```

| Element | Setting |
|---|---|
| Cluster definition | ClusterClass and a `Cluster` object; versions pinned |
| Control plane | 3 nodes behind the CAPO load balancer |
| Workers | one machine deployment, anti-affinity |
| Pod network | Cilium, VXLAN, MTU = network MTU − 50 |
| Ingress | Traefik (Gateway API) behind a load balancer with a floating IP of `svc_public`, PROXY v2 from the load balancer |
| Metrics | in-cluster Prometheus behind a load balancer with a floating IP of `monitoring`, federated by the collector |
| API | floating IP on the administration network, administration sources only |
| Credentials | application credential dedicated to the cluster (restricted, `member` and `load-balancer_member`), created by the operator and copied to the bootstrap instance; never in the Terraform state |

## Reachability matrix

Each row is checked by the acceptance test ([`tests/reachability`](../tests/reachability/README.md)) after deployment; the rows that involve `platform` or the `intranet` plane are checked when the test is given the platform kubeconfig. *Enforced by* names the mechanism that makes the row true.

| From | To | Port | Expected | Enforced by |
|---|---|---|---|---|
| Internet | edge load balancer | 80, 443 | allowed | public floating IP, security group |
| Internet | `web`, `platform`, `isolated` | any | denied | no public address |
| edge Traefik | `web` VMs | 443 | allowed | `svc_public` route, security group |
| edge Traefik | `platform` ingress | 443 | allowed | `svc_public` route, security group |
| `web` | `platform` ingress | 443 | denied | security group (source = edge only) |
| `platform` | `intranet` | any | allowed | router to `intranet` |
| `web` | `intranet` | any | denied | no router to `intranet` |
| `isolated` | `web`, `platform`, `edge` | any | denied | no route |
| Collector | every instance, through its `monitoring` floating IP | metrics ports | allowed | floating IP of `monitoring`, route to the plane range, security group (source = `collector_cidrs`) |
| Any tenant | another tenant, through `monitoring` floating IPs | metrics ports | denied | security group (source = `collector_cidrs` only: every tenant reaches the plane with an address of its range, through source NAT) |
| `isolated` | the Internet | any | denied | no egress router |

## Layer 10 contract

Until cloud-baseline (module v0.2) provides layer 10, the operator must supply the following objects. Layers 20 and 30 find them by name.

| Object | Requirement |
|---|---|
| Networks `svc_public`, `intranet`, `monitoring` | Visible to the tenant projects (shared or external), each with one subnet usable as a router gateway |
| Plane routes | The CIDR of each plane, to be advertised by DHCP in the tenant subnets |
| MTU | The MTU of each plane, and the largest MTU the cloud carries for tenant networks (lower when the tenant overlay itself runs over a tunnel). Tenant networks that join a plane use the smallest of these values (`network_mtu`): OVN routers do not send "fragmentation needed" by default, so a larger MTU silently drops large packets |
| Monitoring zone | A DNS zone shared with the tenant projects, where each stack writes the A records of its instances (collector service discovery) |
| Collector | A collector with an address in the `monitoring` range, outgoing TCP to the metrics ports, and its addresses published (`monitoring.collector_cidrs` of the stacks) |
| Reserved ranges | The ranges tenants must not use for their networks (ranges used by the cloud infrastructure) |
| Public network | A network providing floating IPs reachable from the internet, for the edge load balancer |
| Administration network and sources | An external network for the bastions and the Kubernetes API floating IPs, and the **operator addresses** allowed on them. Recommended: a network distinct from the intranet. With one network for both roles, the administration sources must be specific addresses, never the network range: tenants joining the intranet reach it with addresses of its range ([ADR-0002](adr/0002-platform-kubernetes.md), D6) |
| Octavia | Available to the projects, with a load balancer flavor (amphora topology) |
| Image | An Ubuntu LTS cloud image visible to the projects |
| Flavors | Sizes listed in the sizing table below |
| DNS | A zone per project, or a shared zone where projects may write records (optional, Designate) |
| Quotas | At least the sizing table below, per project |

Security groups are declared by each tenant. A central catalogue shared by RBAC is an operator option that comes with cloud-baseline.

## Sites

Version 1 runs in one site. The code is site-ready so that failover between sites can be added later without restructuring:

| Rule | Why it matters later |
|---|---|
| The site is an input of every stack (cloud connection, availability zone), part of names and of the state key | The same stacks deploy a second site without collision |
| No hand-written address: routes and DNS records come from stack outputs of the same site | Each site generates its own routes |
| Layer 10 contract per site | Site B gets the same planes |
| Short TTL on public DNS records | Failover is a DNS change |

Planned for a later version: an edge per site (active/passive), a failover runbook with a DNS switch, a failover drill that replays the reachability matrix on the second site. Data replication is out of scope.

## Sizing

Indicative minimum to run the whole scenario. Without the `platform` project and its bootstrap machine, the scenario needs 5 instances, 9 vCPU, 9 GiB of RAM, 1 load balancer and 8 floating IPs (1 public, 2 `svc_public`, 5 `monitoring`), plus the optional bastions and, for the reachability matrix, the test collector.

| Project | Instances | vCPU | RAM | Load balancers | Floating IPs |
|---|---|---|---|---|---|
| `edge` | 2 | 4 | 4 GiB | 1 | 1 public + 2 `monitoring` |
| `web` | 2 | 4 | 4 GiB | 0 | 2 `svc_public` + 2 `monitoring` |
| `platform` | 5 (3 control plane, 2 workers) | 10 | 20 GiB | 2 (API, ingress) | 1 `svc_public` (ingress) + monitoring to be defined with the cluster |
| `isolated` | 1 | 1 | 1 GiB | 0 | 1 `monitoring` |
| bootstrap (CAPO management) | 1 | 2 | 4 GiB | 0 | 0 |
| optional bastions (one per tenant) | 1 each | 2 each | 2 GiB each | 0 | 1 each, on the administration network |
| **Total without bastions** | **11** | **21** | **33 GiB** | **3** | **12** |
