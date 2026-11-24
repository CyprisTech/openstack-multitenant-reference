# Who it is for

This reference structures **your projects on an OpenStack cloud** for several tenants: isolated from each other, sharing the common infrastructure, kept available. It owns that architecture and its integration points; the cloud foundation, the platform services' tools and the workloads belong to others ([ADR-0003](../adr/0003-scope-and-boundary.md), D4).

Below, for each profile: what it needs, what is hard for it, what the reference answers, and what stays outside it, with where to look. The release that delivers each answer is in the README's [status](../../README.md#status).

## Profiles

The whole architecture works with a member role only (profiles A and B); a cloud operator (profile C) also provides planes as external networks; a platform services team (profile D) runs its services on the planes.

### A. Platform team on a public or sovereign cloud

A company, a public body or a software vendor running several applications or teams in several projects at a provider (OVHcloud, Infomaniak, Cleura, a Sovereign Cloud Stack cloud), with a **member role** only.

| | |
|---|---|
| Needs | Isolate applications or teams from each other; share a few common services (entry point, monitoring, internal services); no administrator rights |
| What is hard | No external network of one's own and no routing without address translation; network sharing between projects may be forbidden (scs-0126 recommends it); a limit of projects per customer (3 by default at Cleura) and of RBAC policies; every load balancer and public address is billed; providers differ (Octavia, Designate, flavors) |
| Answered | One project per tenant; planes built in a hub project with member credentials only, in one or several regions; a check of the cloud's limits before the first apply (network sharing allowed, quotas, number of projects); isolation test; a tenant added without touching the others; observability pushed to your receivers; availability zones |
| Outside the reference | Projects administered by several organisations; connection to on-premises networks; single sign-on across projects (the provider's IAM) |

### B. Hosting provider or managed-services company

One project per customer, many customers, many domains: the case of a host running websites and business applications for small companies.

| | |
|---|---|
| Needs | Isolation that can be shown to a customer or an auditor; many domains on few public IPv4 addresses; onboarding a customer without touching the others |
| What is hard | The cost of a public address and a load balancer per customer; the customers' TLS certificates; publishing a domain without an outage; billing per customer; backing up the customers' data |
| Answered | Shared entry point routing by SNI to each tenant's service address without decrypting, client address kept (PROXY v2); a domain published in seconds without replacing anything nor losing a request; a tenant exposed with its own address instead; certificates obtained by each tenant (ACME DNS-01); backups of the customers' data through an integration point; isolation test to rerun and show |
| Outside the reference | The backup tool itself; self-service onboarding and billing (the cloud's foundation); WAF and DDoS protection |

### C. Operator of a private OpenStack cloud

An IT department or a host running its own OpenStack, with administrator rights, providing common planes (publication, observability, internal services) to its tenants.

| | |
|---|---|
| Needs | Planes with a stable contract for its tenants, and a frame to consume them |
| What is hard | Names, ranges and MTU that tenants can rely on; address translation or routing; creating projects and quotas; shared DNS zones |
| Answered | Operator planes as external networks with address translation; in `v0.7`, routed in a shared address scope, or segments given to each project behind the operator's gateway ([spec](../specs/operator-segments.md)); the [planes contract](../reference/planes-contract.md) (MTU, reserved ranges); projects, quotas, flavors and images with [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-cloud-baseline) |
| Outside the reference | Operating the cloud itself: deployment, upgrades, databases of OpenStack |

### D. Platform services team

The team that runs a service for every tenant: observability, security and audit, backups, secrets and certificates, internal network services (DNS, time, mirrors, registry), CI/CD runners, or a Kubernetes offer of its own. Level 3 of [ADR-0003](../adr/0003-scope-and-boundary.md): it keeps its tools.

| | |
|---|---|
| Needs | A place for its service, reachable by every tenant that should use it and by nobody else; a contract tenants can rely on |
| What is hard | Reaching tenants that are isolated from each other; admitting the right consumers; pushing or pulling across projects without opening the tenants |
| Answered | A project of shared services joined to a plane with the role `shared`; the flows it opens and who is admitted, stated per [integration point](../reference/integration-points.md); the [shared cluster](../../stacks/shared/kubernetes/README.md) for services that run on Kubernetes, with an internal ingress open to declared consumers; [opening a service](../guides/open-a-service.md) to a new consumer |
| Outside the reference | The tools themselves (Prometheus, Vault, a backup product, Gardener…), which the team chooses and runs |

## Tenant type, not a profile

### E. Teams wanting Kubernetes on OpenStack

Kubernetes is a tenant type of the reference ([ADR-0003](../adr/0003-scope-and-boundary.md), D3), useful to profiles A and B on clouds without a managed offer.

| | |
|---|---|
| What is hard | Cluster API and moving its management into the cluster; building the node image; the cloud controller manager and Octavia; the CNI's MTU; a clean teardown |
| Answered | Self-managed cluster, ClusterClass, node image built with image-builder, Cilium with its MTU, Gateway API ingress, metrics pushed by the cluster's Prometheus, creation and teardown scripted; the lifecycle the landing zone requires (addresses kept, credential rotation, administration path), upgrades and scaling left to Cluster API; the shared cluster, a Kubernetes cluster for shared services ([shared cluster](../../stacks/shared/kubernetes/README.md)) |
| Outside the reference | Kubernetes as a service, clusters created by their users on request (Magnum, Azimuth or Gardener do it; the reference gives each tenant project its cluster, declared by the platform team); multi-tenancy inside a cluster; application GitOps |

## The reader

### F. Architect evaluating the design

A customer, a peer or an architect of another organisation judging whether the design holds. Looks for decisions and their reasons ([ADRs](../adr/README.md)), assumed [trade-offs](trade-offs.md), evidence ([test results](test-results.md)) and an honest boundary — this page.

## Outside the reference, compatible with it

The reference owns one level of [ADR-0003](../adr/0003-scope-and-boundary.md) (D4): how the projects are organised, connected, exposed and kept available. The rest stays yours or your provider's, and connects to it at a stated place.

The [Scope](../../README.md#scope) section of the README shows these levels and what connects to the reference in one picture.

| You need… | How it fits |
|---|---|
| to build or operate the cloud itself | Below the reference: your deployment tool (OpenStack-Ansible, Kolla…) builds the cloud; [`cloud-baseline`](https://github.com/CyprisTech/terraform-openstack-cloud-baseline) creates projects, quotas and operator planes; the reference organises the projects on top. |
| your provider's own landing zone (accounts, identity, billing, a firewall at the hub) | Beside the reference: keep it for what needs the account owner's rights; the reference organises the projects you hold with a member role, with the same model on each OpenStack cloud you use. A firewall at the hub inspects what is routed to it ([ADR-0004](../adr/0004-planes-and-isolation.md)); it isolates projects only if they reach each other through it alone. Isolation stays enforced at every target and tested. Not tested yet on a provider's landing zone. |
| a platform operated for your users (databases, Kubernetes on demand, serverless) | Above the reference: it runs in tenant projects, joins the planes like any tenant and uses the same integration points; projects such as Sovereign Cloud Stack or Azimuth, or a provider's managed offer, operate it. |
| several networks of one project, each with its own router on the same hub plane | Give each network its project: every tenant or shared service is a project ([ADR-0003](../adr/0003-scope-and-boundary.md)), with its own quotas, credentials and isolation. A project already has one router per plane it joins. |
| OpenShift, or another Kubernetes distribution with its own installer | In a tenant project, like the `kubernetes` tenant: a tenant made with terraform-openstack-tenant gives it its network, router and plane attachments, and OpenShift is installed into that network (its installer can use an existing network). Its ingress can sit behind the entry point (SNI, TLS passthrough) or have its own floating IP; its Prometheus can push to the receiver (remote write). Watch the MTU of the cluster network (the planes' overlay), the security groups the installer creates (the admissions of the reference apply at every target, and the isolation test can check them) and the API and ingress addresses held by keepalived (allowed address pairs). Its lifecycle is its own, not Cluster API's. Not provided, not tested. |
| one application in one project | [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) and its examples; the reference starts at several projects. |
| on-premises networks (site-to-site VPN, dedicated links) | A plane: an operator network that reaches your sites, joined by the tenants that need it like any operator plane ([planes contract](../reference/planes-contract.md)). On a cloud where you have a member role only, a VPN gateway in a project of shared services, on the internal services plane. |
| a central firewall inspecting traffic between tenants | A firewall isolates only what cannot go around it. On a cloud of segments (`v0.7`), it is the operator's firewall between the projects' segments. On a hub plane, a firewall as the next hop of the attachments' routes (the stacks route through the transit router today) inspects what goes to the shared services, but the projects still share the plane and reach each other around it. Isolation stays enforced at every target (security groups) and tested. |
| a WAF or DDoS protection | Upstream of the entry point (a provider service or an appliance), or in front of a tenant exposed directly: the entry point passes TLS through by design ([trade-offs](trade-offs.md#1-tls-passthrough-at-the-public-entry-point)). |
| OpenStack together with other clouds | Each cloud keeps its landing zone; the reference covers the OpenStack side and states its integration points. |
| active-active across regions | The reference is ready for an active/passive failover between regions by DNS (`v0.9`), which you run; active-active is a property of your applications and data. |
| a certification (SecNumCloud, C5) | The reference gives tested isolation and integration points for logs, audit and secrets; the rest of the evidence comes from the provider and your organisation. |

## Coverage by need

| Need | A | B | C | Answer |
|---|---|---|---|---|
| Isolation between tenants, proven | ● | ● | ● | security groups at every target, executable test |
| Planes built with a member role | ● | ○ | | hub project, RBAC sharing, transit router |
| Planes provided by the operator | | ○ | ● | external networks with address translation; routed, or segments of the operator, in `v0.7` |
| One entry point for many domains | ○ | ● | | SNI passthrough to service addresses, routes updated in place |
| Certificates of the published domains | ○ | ● | | ACME DNS-01 in each tenant |
| Observability across tenants | ● | ● | ○ | integration point: metrics, logs and audit pushed to your receivers |
| Availability zones, regions, recovery of the architecture | ● | ● | ○ | spread over hosts and zones, an entry point per region, rebuild from code; the failover is yours |
| Egress, DNS, time, mirrors | ● | ● | ● | declared egress, with an optional shared egress; resolvers and time from the cloud; mirrors as an integration point (`v0.8`) ([ADR-0016](../adr/0016-network-services-and-edge-by-level.md)); IPv4, IPv6 after `v1.0` ([ADR-0015](../adr/0015-ipv6.md)) |
| Backups of tenant data, secrets | ● | ● | ○ | integration points |
| Single sign-on, quotas, cost, self-service | ● | ● | ● | not covered: the cloud's foundation |

● central need · ○ secondary need
