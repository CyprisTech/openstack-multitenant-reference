# Who it is for

This reference structures **your projects on an OpenStack cloud** for several tenants: isolated from each other, sharing the common infrastructure, kept available. It owns that architecture and its integration points; the cloud foundation, the platform services' tools and the workloads belong to others ([ADR-0003](../adr/0003-scope-and-boundary.md), D4).

Below, for each profile: what it needs, what is hard for it, what the reference answers, and what stays outside it, with where to look. The release that delivers each answer is in the README's [status](../../README.md#status).

## Profiles

The whole architecture works with a member role only (profiles A and B); a cloud operator (profile C) also provides planes as external networks.

### A. Platform team on a public or sovereign cloud

A company, a public body or a software vendor running several applications or teams in several projects at a provider (OVHcloud, Infomaniak, Cleura, a Sovereign Cloud Stack cloud), with a **member role** only.

| | |
|---|---|
| Needs | Isolate applications or teams from each other; share a few common services (entry point, monitoring, internal services); no administrator rights |
| What is hard | No external network of one's own and no routing without address translation; network sharing between projects may be forbidden (scs-0126 recommends it); a limit of projects per customer (3 by default at Cleura) and of RBAC policies; every load balancer and public address is billed; providers differ (Octavia, Designate, flavors) |
| Answered | One project per tenant; planes built in a hub project with member credentials only, in one or several regions; a check of the cloud's limits before the first apply (network sharing allowed, quotas, number of projects); isolation test; a tenant added without touching the others; observability pushed to your receivers; availability zones |
| Not covered | Projects administered by several organisations; connection to on-premises networks; single sign-on across projects (the provider's IAM) |

### B. Hosting provider or managed-services company

One project per customer, many customers, many domains: the case of a host running websites and business applications for small companies.

| | |
|---|---|
| Needs | Isolation that can be shown to a customer or an auditor; many domains on few public IPv4 addresses; onboarding a customer without touching the others |
| What is hard | The cost of a public address and a load balancer per customer; the customers' TLS certificates; publishing a domain without an outage; billing per customer; backing up the customers' data |
| Answered | Shared entry point routing by SNI to each tenant's service address without decrypting, client address kept (PROXY v2); a domain published in seconds without replacing anything nor losing a request; a tenant exposed with its own address instead; certificates obtained by each tenant (ACME DNS-01); backups of the customers' data through an integration point; isolation test to rerun and show |
| Not covered | The backup tool itself; self-service onboarding and billing (the cloud's foundation); WAF and DDoS protection |

### C. Operator of a private OpenStack cloud

An IT department or a host running its own OpenStack, with administrator rights, providing common planes (Internet, intranet, monitoring) to its tenants.

| | |
|---|---|
| Needs | Planes with a stable contract for its tenants, and a frame to consume them |
| What is hard | Names, ranges and MTU that tenants can rely on; address translation or routing; creating projects and quotas; shared DNS zones |
| Answered | Operator planes as external networks, with address translation or routed in a shared address scope; the [planes contract](../reference/planes-contract.md) (MTU, reserved ranges); projects, quotas, flavors and images with the module's `cloud-baseline` |
| Not covered | Operating the cloud itself: deployment, upgrades, databases of OpenStack |

## Tenant type, not a profile

### D. Teams wanting Kubernetes on OpenStack

Kubernetes is a tenant type of the reference ([ADR-0003](../adr/0003-scope-and-boundary.md), D3), useful to profiles A and B on clouds without a managed offer.

| | |
|---|---|
| What is hard | Cluster API and moving its management into the cluster; building the node image; the cloud controller manager and Octavia; the CNI's MTU; a clean teardown |
| Answered | Self-managed cluster, ClusterClass, node image built with image-builder, Cilium with its MTU, Gateway API ingress, metrics pushed by the cluster's Prometheus, upgrade, scaling and credential rotation, creation and teardown scripted; a cluster for shared services ([spec](../specs/kubernetes-shared-services.md)) |
| Not covered | Clusters on demand; multi-tenancy inside a cluster; application GitOps |

## The reader

### E. Architect evaluating the design

A customer, a peer or an architect of another organisation judging whether the design holds. Looks for decisions and their reasons ([ADRs](../adr/README.md)), assumed [trade-offs](trade-offs.md), evidence ([test results](test-results.md)) and an honest boundary — this page.

## Not the target

| You… | Instead |
|---|---|
| run one application in one project | [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) and its examples |
| span OpenStack and other clouds | Out of scope |
| need active-active across regions | Out of scope: the reference fails over between regions (active/passive) |
| want managed databases, serverless or an operated platform | A provider's managed offer, or projects such as Sovereign Cloud Stack or Azimuth |

## Coverage by need

| Need | A | B | C | Answer |
|---|---|---|---|---|
| Isolation between tenants, proven | ● | ● | ● | security groups at every target, executable test |
| Planes built with a member role | ● | ○ | | hub project, RBAC sharing, transit router |
| Planes provided by the operator | | ○ | ● | external networks, with address translation or routed |
| One entry point for many domains | ○ | ● | | SNI passthrough to service addresses, routes updated in place |
| Certificates of the published domains | ○ | ● | | ACME DNS-01 in each tenant |
| Observability across tenants | ● | ● | ○ | integration point: metrics, logs and audit pushed to your receivers |
| Availability zones, regions, recovery of the architecture | ● | ● | ○ | spread over hosts and zones, an entry point per region, rebuild from code |
| Egress, DNS, time, mirrors, IPv6 | ● | ● | ● | shared services on the planes, declared egress, dual stack |
| Backups of tenant data, secrets | ● | ● | ○ | integration points |
| Single sign-on, quotas, cost, self-service | ● | ● | ● | not covered: the cloud's foundation |

● central need · ○ secondary need
