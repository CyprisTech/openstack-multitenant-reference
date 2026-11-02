# Who it is for

This reference structures **one OpenStack account for several tenants**: isolated from each other, sharing the common infrastructure, kept available. It owns that architecture and its integration points; the cloud foundation, the platform services' tools and the workloads belong to others ([ADR-0003](../adr/0003-scope-and-boundary.md), D4).

Below, for each profile: what it needs, what is hard for it, and what the reference covers. **Proven** means tested on a real cloud ([test results](test-results.md)); **planned** means on the [roadmap](../../README.md#roadmap); **not covered** means outside the reference, with where to look.

## Primary profiles

### A. Platform team on a public or sovereign cloud

A company, a public body or a software vendor running several applications or teams in one account at a provider (OVHcloud, Infomaniak, Cleura, a Sovereign Cloud Stack cloud), with a **member role** only.

| | |
|---|---|
| Needs | Isolate applications or teams from each other; share a few common services (entry point, monitoring, internal services); no administrator rights |
| What is hard | No external network of one's own and no routing without address translation; network sharing between projects may be forbidden (scs-0126 recommends it); a limit of projects per account (3 by default at Cleura) and of RBAC policies; every load balancer and public address is billed; providers differ (Octavia, Designate, flavors) |
| Proven | One project per tenant; planes built in a hub project with member credentials only (interface mode, transit router); isolation test; a tenant added without touching the others |
| Planned | Tests on a public cloud; a preflight check (RBAC sharing allowed, quotas, project count); monitoring as a push integration point; availability zones |
| Not covered | Several accounts or regions joined together (an encrypted overlay is a later direction); connection to on-premises networks; single sign-on across projects (the provider's IAM) |

### B. Hosting provider or managed-services company

One project per customer, many customers, many domains: the case of a host running websites and business applications for small companies.

| | |
|---|---|
| Needs | Isolation that can be shown to a customer or an auditor; many domains on few public IPv4 addresses; onboarding a customer without touching the others |
| What is hard | The cost of a public address and a load balancer per customer; the customers' TLS certificates; publishing a domain without an outage; billing per customer; backing up the customers' data |
| Proven | Shared entry point routing by SNI without decrypting, client address kept (PROXY v2); isolation test to rerun and show |
| Planned | One service address per domain, the entry point never sees the customers' instances; domains published without replacing the entry point; certificates of the published domains; exposure through the shared entry point or through the customer's own load balancer, per tenant ([ADR-0006](../adr/0006-exposure.md)) |
| Not covered | Backups of the customers' data (an integration point, the tool is yours); self-service onboarding and billing (level 1); WAF and DDoS protection |

## Secondary profile

### C. Operator of a private OpenStack cloud

An IT department or a host running its own OpenStack, with administrator rights, providing common planes (Internet, intranet, monitoring) to its tenants.

| | |
|---|---|
| Needs | Planes with a stable contract for its tenants, and a frame to consume them |
| What is hard | Names, ranges and MTU that tenants can rely on; address translation or routing; creating projects and quotas; shared DNS zones |
| Proven | Operator planes as external networks (gateway mode); the [planes contract](../reference/planes-contract.md) (MTU, reserved ranges) |
| Planned | cloud-baseline for projects, quotas, flavors and images; a routed mode without address translation (address scopes) |
| Not covered | Operating the cloud itself: deployment, upgrades, databases of OpenStack |

## Tenant type, not a profile

### D. Teams wanting Kubernetes on OpenStack

Kubernetes is a tenant type of the reference ([ADR-0003](../adr/0003-scope-and-boundary.md), D3), useful to profiles A and B on clouds without a managed offer.

| | |
|---|---|
| What is hard | Cluster API and moving its management into the cluster; building the node image; the cloud controller manager and Octavia; the CNI's MTU; a clean teardown |
| Proven | Self-managed cluster, ClusterClass, node image built with image-builder, Cilium with its MTU, Gateway API ingress, creation and teardown scripted with measured durations |
| Planned | Kubernetes upgrade, scaling, credential rotation; metrics pushed by the cluster's Prometheus; a cluster for shared services ([spec](../specs/kubernetes-shared-services.md)) |
| Not covered | Clusters on demand; multi-tenancy inside a cluster; application GitOps |

## The reader

### E. Architect evaluating the design

A customer, a peer or a recruiter judging whether the design holds. Looks for decisions and their reasons ([ADRs](../adr/README.md)), assumed [trade-offs](trade-offs.md), evidence ([test results](test-results.md)) and an honest boundary — this page.

## Not the target

| You… | Instead |
|---|---|
| run one application in one project | [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant) and its examples |
| span OpenStack and other clouds | Out of scope |
| need active-active across regions | Out of scope; failover between sites is on the roadmap |
| want managed databases, serverless or an operated platform | A provider's managed offer, or projects such as Sovereign Cloud Stack or Azimuth |

## Coverage by need

| Need | A | B | C | State |
|---|---|---|---|---|
| Isolation between tenants, proven | ● | ● | ● | proven |
| Planes built with a member role | ● | ○ | | proven on a private cloud with member credentials; public cloud planned |
| Planes provided by the operator | | ○ | ● | proven (gateway mode); routed mode planned |
| One entry point for many domains | ○ | ● | | proven; service addresses and live routes planned |
| Certificates of the published domains | ○ | ● | | planned |
| Monitoring across tenants | ● | ● | ○ | integration point: pull proven, push planned |
| Availability zones, sites, recovery of the architecture | ● | ● | ○ | planned |
| Egress, DNS, time, mirrors, IPv6 | ● | ● | ● | planned |
| Logs, audit, backups of tenant data, secrets | ● | ● | ○ | integration points, planned |
| Single sign-on, quotas, cost, self-service | ● | ● | ● | not covered: level 1 |

● central need · ○ secondary need
