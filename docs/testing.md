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
