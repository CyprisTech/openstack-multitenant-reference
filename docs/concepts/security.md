# Security model

Who holds which credential, how far a compromised component reaches, and what inspects the traffic between projects. The flows themselves, row by row, are the [isolation matrix](../reference/isolation-matrix.md); the [isolation test](../guides/check-isolation.md) checks them on a deployment. The decisions are [ADR-0004](../adr/0004-planes-and-isolation.md) (planes and isolation) and [ADR-0005](../adr/0005-stacks-contracts-and-access.md) (stacks, contracts and access); the [architecture](architecture.md) describes the topology they apply to.

**Status:** delivered; every statement on lateral movement is a row of the isolation test or a step of the test procedure.

## Identity and credentials

| Who | Credential | Rights |
|---|---|---|
| Each stack | one application credential of its own project, in the `clouds.yaml` of whoever applies the stack | `member` (and `load-balancer_member` where it creates load balancers); nothing on another project ([ADR-0005](../adr/0005-stacks-contracts-and-access.md)) |
| Each Kubernetes cluster | an application credential dedicated to the cluster, created by an administrator and copied to the bootstrap instance, then held by Cluster API, the cloud controller and Cinder CSI | the same roles, in the cluster's project; rotated without downtime ([lifecycle guide](../guides/kubernetes-lifecycle.md)) |
| Administrators | their SSH keys on the bastions and instances; their addresses in the inputs (`admin`, `bastion.ssh_cidrs`) | SSH and the Kubernetes APIs, from those addresses only ([administration paths](architecture.md#administration-paths)) |

The states hold what the stacks are given, the credentials of a DNS provider for the certificates among them: keep them in a backend with access control and encryption, itself backed up ([rebuild](../guides/rebuild.md)). No credential of a cluster is in a state.

## Lateral movement

The shared services are the only points that several tenants reach, and the entry point is the only one that reaches the tenants: a hub-and-spoke design concentrates lateral movement there rather than removing it. Their reach is bounded by the security groups of each target and checked by the isolation test.

| Shared service | Reaches | Never reaches |
|---|---|---|
| Entry point | the tenants' service addresses, on their service port | a tenant's instances or other ports; the other shared services, except the receiver it pushes to |
| Receiver | nothing: every flow to it is pushed | a tenant, the other shared services |
| Internal service | nothing: its consumers call it | a tenant, the other shared services |
| Hub project | runs no instance | — |

### If a component is compromised

**The entry point** can send requests to every published application, on its service port only, and holds no key: TLS ends in the tenant ([ADR-0006](../adr/0006-exposure.md)). It is the largest reach of the design, and the one the entry point needs to work.

**A tenant** reaches a shared service on the ports of the service it consumes, and no other. SSH is admitted from the administrators' addresses only ([ADR-0005](../adr/0005-stacks-contracts-and-access.md)).

**A published tenant that consumes internal services** is the most exposed tenant on the internal services plane. Compromised, it reaches the services that declared it as a consumer, on their service ports, and no other tenant. Therefore:

- join that plane only to consume a service;
- do not admit a published tenant to sensitive services (secrets, administration of the directory, backups): give it a narrower service in front of them;
- when the stakes justify it, split the tenant in two: a published front without the internal services plane, calling a back that offers its service to it and consumes the internal services.

### Rules that keep the reach small

**Routes are not the boundary.** Routes exist between the shared services of a plane ([ADR-0004](../adr/0004-planes-and-isolation.md)): only the security groups of the target close the flows that are not declared.

**A tenant that offers a service to another** takes the role `shared` on a plane, and the other the role `tenant`: one provider, its consumers, one direction of opening, as AWS PrivateLink, not VPC peering ([How a tenant joins a plane](plane-attachment.md#a-tenant-offering-a-service-to-another)).

**A Kubernetes cluster is published or shared, not both**: an entry from the Internet must not sit on a cluster that every tenant of the internal services plane reaches.

**Spoofed sources stay blind.** Port security filters the ports of the instances, not those of the routers. A project allowed by the cloud's policy to disable port security on its own ports can send packets with another project's address through its router. They are blind: the answer goes to the real owner, so no TCP connection is established, and every service of the scenario listens on TCP. Services answering on UDP, such as name resolution and time, allow reflection; their integration point states it. The [test procedure](../reference/test-procedure.md) checks this on each cloud.

## Inspection and flow logs

There is no central point that inspects or logs the traffic between projects: each target filters for itself. Two answers keep the design:

- **Flow logs:** the Neutron *network log* extension records what the security groups accept and drop, with the OVN driver. It is enabled by the cloud operator, and the logs are written on the compute hosts.
- **Central inspection:** a firewall in the path, on top of the security groups of the targets, not instead of them. It isolates only what cannot go around it: between segments of the operator (`v0.7`), or between projects that reach each other through it alone; on a shared plane, the projects reach each other without crossing it ([trade-offs](trade-offs.md#7-isolation-on-the-publication-plane)).

Two more choices that an architect may discuss are argued in the trade-offs: the [hub planes as shared segments](trade-offs.md#19-hub-planes-are-shared-segments) and the [bastion per stack](trade-offs.md#20-a-bastion-per-stack).

## Beyond the network

The integrity of what a shared service distributes (images, packages, name resolution) and whom it authenticates are properties of the tool chosen for it, not of this architecture ([ADR-0003](../adr/0003-scope-and-boundary.md), D4, level 3).
