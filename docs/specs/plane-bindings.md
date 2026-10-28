# Spec: plane bindings for public clouds

- **Status:** draft, not started
- **Milestone:** after v0.2 (cloud-baseline); to be decided by an ADR once the spike below is done

## Problem

The [layer 10 contract](../architecture.md#layer-10-contract) asks for planes (`svc_public`, `monitoring`, `intranet`) that are **external networks**: tenants join them through a router with source NAT and publish on them with a **floating IP of the plane** (ADR-0001, D2). Creating an external network needs the Neutron admin role. That fits a private or sovereign cloud run by its operator, not a public cloud: on OVHcloud Public Cloud, for example, the only external network is the Internet one (`Ext-Net`).

## Direction

A plane can be realised in two ways, chosen per plane and per site:

| | External plane (today) | Shared internal plane |
|---|---|---|
| Created by | the cloud operator (admin) | the customer: a private network shared across projects (OVHcloud vRack, Neutron RBAC `access_as_shared`), or a single project |
| A tenant joins it with | a router whose gateway is on the plane (source NAT) | a router interface on the plane, or a second port on the instances; no NAT |
| A service is published with | a floating IP of the plane | the fixed address of its port on the plane |
| Others see the tenant as | the router's gateway address | the instance's own address |
| Isolation rests on | routers and security groups | security groups only: every tenant is on the same layer-2 segment |
| Public entry point | floating IP on the public network | unchanged (floating IP on the Internet network) |

The stacks would take the binding mode as an input per plane; the module may need a "port on a shared network" building block. The reachability matrix does not change: it is what proves that isolation still holds with security groups only.

## Questions for the spike

1. Can a project share one of its networks with another project of the same account (RBAC `access_as_shared`)? With `access_as_external`?
2. Is a vRack private network visible from two Public Cloud projects, and can a router interface be attached to it?
3. MTU of vRack private networks.
4. Do Octavia load balancers accept members and VIPs on a vRack network?
5. Quotas and costs of the extra routers, ports and load balancers.

## Done when

- An ADR records the decision, from the spike results.
- The stacks deploy on a public cloud with shared internal planes.
- The reachability matrix passes there, unchanged.
