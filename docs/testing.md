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
