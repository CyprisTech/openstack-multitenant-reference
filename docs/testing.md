# Testing

Each stack is tested on a real OpenStack cloud before it is merged: **apply → empty plan after apply → destroy**, plus functional checks. The tenants of the scenario run in one test project, each stack with its own `clouds.yaml` entry (see [ADR-0001](adr/0001-reference-architecture.md), D1).

## Environment

Private cloud, OpenStack 2025.1 deployed with OpenStack-Ansible (Nova, Neutron with OVN, Cinder, Glance, Octavia amphora, Designate). Project-scoped application credential with the `member` and `load-balancer_member` roles. OpenTofu 1.13.2, provider `terraform-provider-openstack/openstack` 3.4.0, module `terraform-openstack-tenant` v0.1.1.

## Results

### Stack 20 — public entry point (2026-10-27)

| Check | Result |
|---|---|
| Apply | ✅ 38 resources in 172 s (amphora included) |
| Empty plan after apply | ✅ |
| Placement | ✅ the two Traefik instances on two different hosts (hard anti-affinity) |
| Health monitors | ✅ the four members `ONLINE` (TCP on 80 and 443) |
| Port 80 through Octavia with the PROXY protocol | ✅ `301` to `https://` |
| Rolling replacement of the instances, one at a time | ✅ one member stayed `ONLINE` during each replacement; plan empty afterwards |
| Destroy | ✅ 38 resources in 88 s, no leftover |
| SNI routing and PROXY v2 to a backend | pending: needs stack 30 `web` |

Finding: on the first run the resolvers of the edge network were only reachable through an intranet plane that the edge does not join. The first boot could not install Podman nor pull the Traefik image, and the members stayed in `ERROR`. Fixed by using resolvers reachable through the public network; the requirement is now stated in the stack documentation.

Observation: a TLS connection with an unknown server name is answered by Traefik with its default self-signed certificate and a `404`.

### Stack 30 `web` and end-to-end path (2026-10-27)

| Check | Result |
|---|---|
| Apply, empty plan after apply | ✅ |
| Routes generated from the `web` outputs and rolled onto the entry point, one instance at a time | ✅ |
| Port 80 redirect, unknown server name answered `404` | ✅ |
| Backends unreachable directly from outside the entry point | ✅ |
| Bastions (floating IP on an administration network, second port on the tenant network) | ✅ |
| SNI routing and PROXY v2 end to end, after the fixes below | ✅ 12/12 requests `200`, both domains, spread over both backends; nginx logs the real client address |
| Rolling replacement of the six instances after the MTU change, plans empty afterwards | ✅ |

Findings:

- **Reserved range.** A web network in `10.30.0.0/24` could not route at all (ARP answered, no packet crossed any router), while `10.21.0.0/24` worked. The layer 10 contract now asks the operator to publish the ranges tenants must not use.
- **Path MTU black hole.** Small packets crossed `svc_public`, large ones were dropped: the tenant networks used MTU 1442, the planes 1382, and the tenant overlay of the test cloud runs itself over a tunnel. A packet capture on the backend showed the 1390-byte TLS segment retransmitted until timeout while the 37-byte tail was acknowledged. Fixed by `network_mtu = 1362` on every network of the stacks; the contract now asks the operator to publish the MTUs.
- **cloud-init.** nginx failed to start at package installation because the demo certificate was created later; the certificate is now created in `bootcmd`.
- **Bastion routes.** The second interface of a bastion received the default route, plane routes and resolvers of the tenant network; DHCP routes and resolvers are now ignored on that interface.

### Two floating IPs on one port (2026-10-27)

Test configuration: [`tests/integration/dual-floating-ip`](../tests/integration/dual-floating-ip/README.md). Purpose: decide how the monitoring plane reaches tenant instances (option B: a floating IP per plane, with DNS records).

| Check | Result |
|---|---|
| Neutron accepts a floating IP from `svc_public` and one from `monitoring` on the same fixed IP, through two routers | ✅ both `ACTIVE` |
| From an instance of another tenant (routed source): TCP to the target through `svc_public` and through `monitoring`, three times each | ✅ 6/6 |
| Plan empty after apply, destroy | ✅ 41 resources, destroyed in 25 s, no leftover |
| From a host attached directly to the `monitoring` network to the `monitoring` floating IP | not conclusive: the security groups of that host allow no outgoing TCP on its monitoring port (ARP answered, SYN dropped at the source) |

Findings:

- **Replies follow the routes of the instance.** A floating IP on a plane answers only clients whose address is routed back through that plane's router: the plane CIDR is advertised by DHCP, so clients inside the plane work. A client whose address is outside the advertised ranges (for example an administration network reached without source NAT) gets its replies through the default gateway and the connection fails. This is why bastions use their administration router as default gateway.
- **Security groups of the collector.** A host used as a test source had a monitoring port whose security groups allow scraping *into* it (ingress) but no outgoing TCP: its connections never left. A collector on the monitoring plane needs an egress rule to the metrics ports of the plane range.

### Full scenario and reachability matrix (2026-10-27)

Stacks `20-public-edge`, `30-tenants/web` and `30-tenants/isolated` with bastions, the test collector, monitoring floating IPs and DNS records (module commit `fa88feb`, after `v0.1.1`; the same code is released as `v0.1.2`).

| Check | Result |
|---|---|
| Apply: collector 17, entry point 60, `web` 48, `isolated` 28 resources | ✅ |
| Routes generated from `web` and rolled onto the entry point, one instance at a time | ✅ |
| Empty plan after apply, four configurations | ✅ |
| HTTPS end to end through both domains | ✅ 6/6 `200`, both backends, real client address seen by nginx |
| A records in the shared monitoring zone, one per instance | ✅ 5 records, resolvable |
| **Reachability matrix** (`tests/reachability/check.py`) | ✅ **27/27 rows as expected** |
| Destroy, four configurations | ✅ 153 resources, no leftover (instances, load balancers, networks, routers, volumes, floating IPs, DNS records) |

The matrix covers: the entry point from the outside; the web backends reachable from the entry point only; the collector reaching the metrics of every instance (node exporter, Traefik metrics); no tenant reaching the metrics of another through the monitoring plane; no route between tenants; `isolated` reaching neither the published addresses, nor the other tenants, nor the Internet.

Finding: every tenant joins the monitoring plane through a router with source NAT, so seen from the plane all tenants have addresses of the plane range. Metrics ports opened to the plane range would let tenants scrape each other: they are now opened to the collector's addresses only (`monitoring.collector_cidrs`).

### Kubernetes node image (2026-10-28)

| Check | Result |
|---|---|
| Build network: apply, empty plan after apply | ✅ 13 resources |
| Image build with image-builder v0.1.55, Ubuntu 24.04 | ✅ 25 min, private image of 2.1 GiB; the temporary instance, volume, floating IP and key pair deleted by Packer |
| Boot from the image | ✅ kubeadm and kubelet v1.36.5, containerd 2.3.2, crictl 1.36.0, kubelet and containerd enabled, 7 images preloaded |
| SSH restricted to two `/32` administration sources, routed through the administration router | ✅ |
| Destroy of the check instance and of the build network | ✅ no leftover; the image is kept |

Findings:

- The template of image-builder has no default for `volume_type`: `build.json` must set it (empty string for the default type).
- An administration source must be the address **as seen on the administration network**. Through source NAT it is the address of a router, and a machine may leave through a router other than the one its gateway suggests. Three attempts failed with guessed addresses before the source was read on the instance with `$SSH_CLIENT` (see `tests/integration/node-image`).

### Stack 30 `platform`: Kubernetes with Cluster API (2026-10-28)

Node image `ubuntu-2404-kube-v1.36.5` (8 GiB virtual size), Cluster API v1.14.3, CAPO v0.15.1, CAAPH v0.6.4, ORC v2.6.0, Cilium 1.20.4, OpenStack cloud controller manager and Cinder CSI 2.36.5, Traefik chart 42.1.3, Prometheus chart 29.39.0. Three control-plane nodes and two workers (2 vCPU, 4 GiB, 15 GiB root volumes).

| Check | Result |
|---|---|
| Stack apply (network, routers to the planes, server groups, bootstrap instance), empty plan | ✅ 27 resources |
| `create-cluster.sh`: kind, Cluster API, cluster, add-ons, `clusterctl move` | ✅ after the fixes below; the cluster manages itself |
| API: floating IP on the administration network, admitted sources | ✅ operators, plus the bootstrap instance until the move; refused from elsewhere |
| Ingress through the entry point, SNI passthrough, TLS terminated by Traefik (Gateway API) | ✅ 12/12, both demonstration pods, client address preserved (`X-Real-Ip`) |
| Prometheus federation from the collector | ✅ HTTP 200, 34 `up` series, all up |
| Reachability matrix with the platform rows (ADR-0002, D8) and the intranet demonstration service | ✅ 42/42 rows |

Findings, all fixed in the stack:

1. **Cloud API names.** The cluster resolvers must resolve the cloud API endpoints: Cluster API calls them from kind, the cloud controller manager and Cinder CSI from the cluster. Public resolvers did not know the internal Keystone name.
2. **Private certificate authority.** The controllers do not trust a private CA of the cloud APIs by default: `create-cluster.sh` passes it to Cluster API, ORC (key `cacert`), the cloud controller manager and Cinder CSI (`ca-file`).
3. **MTU of kind.** kind takes the MTU of the default Docker bridge (1500), larger than the cluster network (1362): large replies of the cloud APIs were dropped silently. Docker on the bootstrap instance now uses the network MTU.
4. **API sources.** The bootstrap instance reaches the API floating IP with its own floating IP, which the load balancer did not admit. Templates are immutable, so the admitted sources are a variable of the Cluster: the operators, plus the bootstrap instance (read from Neutron) until `clusterctl move`, and again during teardown.
5. **Cloud controller manager and DNS.** With host networking it resolved names through CoreDNS, which waits for the nodes the controller initializes: a deadlock. It now uses the node resolver (`dnsPolicy: Default`).
6. **`clusterctl move` too early.** The cluster is `Available` as soon as the first control-plane node is up; `clusterctl move` refuses to run while a machine is provisioning. The script now waits for every machine.
7. **ORC Image after the move.** `clusterctl move` did not carry the ORC `Image`, and the machines waited for it. The script declares it again in the workload cluster.
8. **Helm release names.** After the move, CAAPH reconciled the proxies with new generated release names and installed Prometheus twice. Release names are now fixed.
9. **Two PROXY headers.** The entry point sends a PROXY v2 header; with PROXY on the cluster load balancer too, Traefik received two headers and the TLS handshake failed within milliseconds. The load balancer now passes the entry point's header through (TCP pools), with `externalTrafficPolicy: Local` so that Traefik sees the load balancer as peer and trusts the header, and two Traefik replicas on two nodes.

Observation: the node image's virtual size is the minimum root disk of every node. The first build, on a 20 GiB volume, forced 20 GiB per node; rebuilt on 8 GiB, node disks are chosen per role by the cluster.

### Platform hardening and first day-2 operation (2026-10-28)

Remediation (MachineHealthCheck), certificate rotation (`rollout.before.certificatesExpiryDays`), kubelet serving certificates approved by kubelet-csr-approver, metrics-server. Applied to the running cluster: the new ClusterClass templates replaced the five machines one at a time, with an availability probe through the entry point every 5 seconds.

| Check | Result |
|---|---|
| Server-side dry run of every object | ✅ |
| Rolling replacement of the five machines (three control-plane nodes, two workers) | ✅ about 45 minutes, after the volume quota was raised |
| MachineHealthCheck | ✅ the first replacement machines, stuck without a volume, were marked unhealthy after 20 minutes and recreated |
| Kubelet serving certificates (`kubelet-serving` CSRs) approved; `kubectl top nodes` | ✅ |
| Reachability matrix after the replacement | ✅ 42/42 |
| Availability through the entry point during the replacement | ⚠️ 647 of 658 requests answered: 1 lost when a worker running Traefik was drained, then about 45 seconds without answer (19:01:27 to 19:02:15) |

Findings:

1. **Volume quota.** A rolling replacement creates one machine before deleting one (`maxSurge: 1`), for the control plane and the workers at the same time: the project needs two free volumes, and the size of two root volumes, on top of the running cluster.
2. **Availability during a replacement.** With `externalTrafficPolicy: Local`, a node that loses its Traefik pod stays a member of the ingress load balancer until the health monitor marks it down, and a new node becomes a member only once the cloud controller manager updates the pool. Requests are lost in between. To do: a PodDisruptionBudget for Traefik, and shorter health monitor intervals on the ingress load balancer.

The routes publication script (`scripts/publish-routes.sh`, replacing the entry point instances one at a time) lost 8 of 179 requests in the same way at the entry point: the load balancer keeps sending to the instance being deleted until its monitor reacts. To do: take the member out of the pools before replacing the instance.

