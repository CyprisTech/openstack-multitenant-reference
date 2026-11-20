# ADR-0012: Resilience, what the reference places and what it tests

- **Status:** Accepted
- **Date:** 2026-11-13
- **Deciders:** maintainers
- **Refines:** [ADR-0003](0003-scope-and-boundary.md) D4 (in scope: high availability, availability zones, sites and the recovery of the architecture); [ADR-0001](0001-reference-architecture.md) D9 consequences (failover runbook and drill); [ADR-0004](0004-planes-and-isolation.md) D5 (several regions)

## Context

ADR-0003 puts high availability, availability zones, sites and the recovery of the architecture in scope, without saying where the reference's part stops and what proves it. Read broadly, it would mean testing the loss of a zone and the failover of a region, which needs a cloud with several zones and several regions, or a simulated one, and turns the reference into a test of OpenStack's own features.

The landing zones of the large providers draw the line the same way:

| | Zones and regions in the landing zone | Availability and disaster recovery | What is tested |
|---|---|---|---|
| Azure ([Cloud Adoption Framework](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/management-business-continuity-disaster-recovery)) | Region-agnostic architecture, a connectivity hub per region | A design area states the requirements; the recovery of each workload is the workload's | Deployment |
| AWS ([Landing Zone Accelerator](https://docs.aws.amazon.com/solutions/latest/landing-zone-accelerator-on-aws/sample-configurations.html)) | Enabled regions and subnets per zone in the network configuration, a transit gateway per region | Recovery strategies (backup and restore, pilot light, warm standby, active/active) belong to the workloads | The configuration |
| Google Cloud ([enterprise foundation](https://github.com/terraform-google-modules/terraform-example-foundation)) | Shared networks with subnets, NAT and DNS in two regions | Separate blueprints | The integration tests check that the subnets exist in both regions |
| OVHcloud ([3-AZ regions](https://docs.ovhcloud.com/pl/guides/public-cloud/public-cloud-cross-functional/3az-ref-architecture)) | Zonal services are not spread automatically: one instance per zone | Off-site replication against the loss of a region, by the customer | — |

A landing zone makes the foundation ready for several zones and regions, states what the cloud and the workloads must provide, and tests that it is deployed where it should be. It does not test failover.

## Options considered

1. **Test the behaviour** on the loss of a zone and the failover of a region, on a multi-zone, multi-region cloud or a simulated one. It proves the most, but it tests OpenStack's features more than the reference, and it needs a cloud with several zones and regions, or a simulation of one, which would mostly test the simulation.
2. **Place and state, test the placement** (chosen). The reference spreads what it deploys over the zones and sites it is given, states its requirements on the cloud and on the workloads, and tests the placement and the deployment.
3. **Leave zones and regions to the deployer.** Simple, but the stacks would have to be rewritten to spread over zones, and the reference would no longer answer the question of its resilience design area.

## Decision

**D1 — The reference places; the cloud and the workloads behave.**

| | The reference | The cloud | The workloads |
|---|---|---|---|
| A host | spreads the instances of a role (anti-affinity) | | |
| An availability zone | spreads the instances, the Kubernetes nodes and the volumes over the zones it is given | the planes and router gateways present in every zone; storage zones; load balancers spread over zones | |
| A region | one site per state: its planes, hub and entry point; the hubs joined by an encrypted overlay; short TTL on public records | | decide and run the failover; replicate their data |
| The architecture itself | rebuilt from code in a documented order; states in a backend that is itself protected | | |

**D2 — What is tested.**

- **Placement, without a cloud.** `tofu test` with a mocked OpenStack provider: nothing is created, the API answers are simulated, and the test checks what each stack would ask the cloud for. For example, four instances over three zones are placed in the first, second, third and first zone; a Kubernetes cluster over three zones gets one machine deployment per zone. It proves the code, not the cloud's behaviour.
- **Deployment, on a real cloud.** The end-to-end campaign, on a cloud with one zone, from empty projects. A stack given its former single zone as a list of one plans no change.
- **Several sites, on a real cloud.** The stacks applied twice in the same cloud, as two sites with different names and projects: both deploy without a conflict of names, ranges or DNS records, which proves the code is ready for several regions.
- **The routes between sites, without a cloud.** The input of the planes stack that lists the ranges of the other sites and routes them to an overlay gateway: a mocked test checks the routes and admission rules it produces. The traffic through a real overlay between regions is not tested.
- **Recovery of the architecture, on a real cloud.** Every campaign rebuilds the whole architecture from empty projects, in the documented order.

**D3 — What is not tested by the maintainers, and said so.** The behaviour on the loss of a zone or a region, the failover between regions and the recovery of tenant data. The reference is compatible with an active/passive failover by DNS and with a recovery plan; running and rehearsing them is the deployer's, as with any landing zone.

**D4 — Requirements are documented** as such: what the cloud must provide (planes and router gateways in every zone, storage zones aligned with compute zones, load balancers spread over zones, three zones for the quorum of a Kubernetes control plane) and what the workloads must do (replicate their data, decide the failover, set their recovery objectives).

## Consequences

- No multi-zone or multi-region test infrastructure is needed; the campaign stays on a cloud with one zone.
- The stacks take a list of zones instead of one (`v0.5`); the planes stack gets a hook for the ranges of other sites, routed to an overlay gateway (`v0.8`).
- The consequence of ADR-0001 D9 that planned a failover runbook and drill by the maintainers no longer applies: the architecture states how to fail over; the deployer writes and rehearses the runbook.
- The documentation says, for each resilience claim, whether it is tested by the maintainers.
