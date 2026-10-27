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

Stacks `20-public-edge`, `30-tenants/web` and `30-tenants/isolated` with bastions, the test collector, monitoring floating IPs and DNS records (module `fa88feb`, after `v0.1.1`).

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
