# Technology landscape

```mermaid
block-beta
  columns 1
  block:TESTS:1
    columns 6
    tT["Tests"] t1["Integration tests on a real cloud"] t2["Reachability matrix"] space space space
  end
  block:OBS:1
    columns 6
    tO["Monitoring"] o1["Monitoring plane floating IPs"] o2["Shared DNS zone"] o3["Prometheus federation"] space space
  end
  block:ING:1
    columns 6
    tI["Kubernetes ingress"] i1["Traefik"] i2["Gateway API"] space space space
  end
  block:CNI:1
    columns 6
    tN["Pod network"] n1["Cilium · VXLAN"] space space space space
  end
  block:CI:1
    columns 6
    tC["Cloud integration"] c1["OpenStack cloud controller manager"] c2["Cinder CSI"] space space space
  end
  block:ADD:1
    columns 6
    tA["Kubernetes add-ons"] a1["CAAPH"] a2["Helm"] space space space
  end
  block:LC:1
    columns 6
    tL["Kubernetes lifecycle"] l1["Cluster API"] l2["CAPO"] l3["ORC"] l4["kind · clusterctl move"] space
  end
  block:IMG:1
    columns 6
    tM["Kubernetes node image"] m1["image-builder"] m2["Packer"] m3["Ubuntu 24.04"] space space
  end
  block:ADM:1
    columns 6
    tD["Administration"] d1["Bastions"] d2["Administration network"] space space space
  end
  block:EDGE:1
    columns 6
    tE["Public entry point"] e1["Octavia · TCP · PROXY"] e2["Traefik on VMs · SNI passthrough"] space space space
  end
  block:NET:1
    columns 6
    tW["Network isolation"] w1["Project per tenant"] w2["Shared planes"] w3["Router per plane"] w4["Security groups by source"] space
  end
  block:IAC:1
    columns 6
    tX["Infrastructure as code"] x1["OpenTofu / Terraform"] x2["terraform-openstack-tenant"] space space space
  end
  block:CLOUD:1
    columns 6
    tK["Cloud"] k1["Nova"] k2["Neutron · OVN"] k3["Cinder"] k4["Octavia"] k5["Designate"]
  end
  classDef layer fill:#ffffff,stroke:#ffffff,color:#111827,font-weight:bold
  classDef infra fill:#dbeafe,stroke:#1d4ed8,color:#1e3a8a
  classDef iac fill:#e5e7eb,stroke:#4b5563,color:#111827
  classDef net fill:#ffedd5,stroke:#c2410c,color:#7c2d12
  classDef k8s fill:#ede9fe,stroke:#6d28d9,color:#4c1d95
  classDef runtime fill:#dcfce7,stroke:#15803d,color:#14532d
  classDef obs fill:#fef9c3,stroke:#a16207,color:#713f12
  classDef test fill:#cffafe,stroke:#0e7490,color:#164e63
  class tT,tO,tI,tN,tC,tA,tL,tM,tD,tE,tW,tX,tK layer
  class k1,k2,k3,k4,k5 infra
  class x1,x2 iac
  class w1,w2,w3,w4,e1,e2,d1,d2 net
  class m1,m2,m3,l1,l2,l3,l4,a1,a2 k8s
  class c1,c2,n1,i1,i2 runtime
  class o1,o2,o3 obs
  class t1,t2 test
```

Colours by family: blue, the cloud; grey, infrastructure as code; orange, network, entry point and administration; violet, Kubernetes image, lifecycle and add-ons; green, components running in the cluster; yellow, monitoring; cyan, tests.

One row per layer of the architecture: what is used, what was considered instead, and why. The reasoning is in the ADRs and in [trade-offs.md](trade-offs.md); this page is the map.

| Layer | Used | Alternatives considered | Why this one | Decision |
|---|---|---|---|---|
| Cloud (IaaS) | OpenStack: Nova, Neutron with OVN, Cinder, Octavia (amphora), Designate | — | The target: private and sovereign OpenStack clouds | [ADR-0001](adr/0001-reference-architecture.md) |
| Infrastructure as code | OpenTofu or Terraform, module [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant), one state per stack | Heat, Ansible, Pulumi | Declarative, plan before apply, one module for every tenant; works without admin rights | ADR-0001, D1 |
| Network isolation | One project per tenant, shared planes (`svc_public`, `monitoring`, `intranet`), one router per plane, floating IP of the plane to publish, security groups by source | One flat shared network; Neutron RBAC between projects | Every flow is explicit, and each one is a row of the reachability matrix | ADR-0001, D2 and D6 |
| Public entry point | Octavia (TCP, PROXY) in front of two Traefik VMs, SNI passthrough, PROXY v2 to backends | Octavia only; Traefik in Kubernetes; HAProxy | TLS stays with each tenant; no orchestrator in front of the tenants; one proxy technology across the architecture | ADR-0001, D8 |
| Administration | One bastion per tenant, floating IP on the administration network, specific operator addresses | VPN; SSH through the monitoring plane | Small, auditable surface, per tenant | ADR-0002, D6 |
| Monitoring | Floating IP of the monitoring plane per instance, A records in a shared zone, one collector admitted by address; Prometheus federation for Kubernetes | Push (`remote_write`); one Prometheus per tenant reachable from everywhere | The collector stays in control; tenants cannot scrape each other | ADR-0001, D2; ADR-0002, D5 |
| Kubernetes node image | [image-builder](https://github.com/kubernetes-sigs/image-builder), OpenStack builder (Packer), Ubuntu 24.04 | Generic cloud image with cloud-init installs | Reproducible, versioned with Kubernetes, fast and offline-friendly node boot | ADR-0002, D1 |
| Kubernetes lifecycle | Cluster API with CAPO (ClusterClass), ORC for OpenStack resources, bootstrap in kind then `clusterctl move` | Magnum, Kubespray, RKE2, Talos | Upstream standard, declarative upgrades and machine replacement, no extra product to run | ADR-0002, D2 and D3 |
| Kubernetes add-ons | Cluster API Add-on Provider Helm (CAAPH) | Flux or Argo CD; manifests applied by script | Add-ons declared next to the cluster and moved with it | ADR-0002, D1 |
| Cloud integration | OpenStack cloud controller manager, Cinder CSI | — | The reference integration of Kubernetes with OpenStack | ADR-0002, D1 |
| Pod network | Cilium, VXLAN, MTU of the network minus 50 | Calico | eBPF datapath, policies at layers 3 to 7, flow visibility | ADR-0002, D4 |
| Kubernetes ingress | Traefik with the Gateway API, behind an Octavia load balancer with a floating IP of `svc_public` | Envoy Gateway; ingress-nginx (retired) | Same proxy as the entry point; Gateway API and PROXY protocol supported | ADR-0002, D5 |
| Tests | Integration tests on a real cloud: apply, empty plan, functional checks, destroy; executable reachability matrix | Static review only | Isolation claims become a test that fails | ADR-0001, D6 |
