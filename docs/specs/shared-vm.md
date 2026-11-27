# Spec: shared services on virtual machines

- **Status:** Proposed — its release is given in the README's [status](../../README.md#status)
- **Related:** [ADR-0006](../adr/0006-exposure.md) (one service address), [ADR-0008](../adr/0008-tenant-certificates.md) (certificates), [ADR-0010](../adr/0010-kubernetes-shared-services.md) (the shared cluster), [ADR-0016](../adr/0016-network-services-and-edge-by-level.md) (egress, names), [ADR-0018](../adr/0018-deployment-tool.md) (`lz`), [`stacks/shared/kubernetes`](../../stacks/shared/kubernetes/README.md), [`stacks/tenants/vm`](../../stacks/tenants/vm/README.md)

## Problem

Only Kubernetes has a stack for shared services. Many services an organisation offers its tenants on the internal services plane run on virtual machines: a database, a directory, an artifact repository, a license server. An adopter today writes that stack alone, or declares the project `existing` and keeps its admission, names and certificates outside the landing zone. The reference's own test uses a fixture, `tests/fixtures/internal-service`, with one instance in one zone and an HTTP server on port 8080: it proves the admission, not a service one would run.

## Goal

A stack `stacks/shared/vm` for a shared service on virtual machines, with the same contract as the shared cluster: an attachment with role `shared` on the internal services plane, the consumers admitted by their addresses and nobody else, one address per service, names in the internal zone, certificates from an ACME directory, the metrics agent. The adopter brings the workload; the stack brings what the landing zone requires around it. `lz` deploys it as a shared service of type `vm`, and the reference scenario uses it in place of the fixture, which is removed.

Out of scope: running the workload (backups, replication, upgrades of the database are the service's, as for the shared cluster, ADR-0010 D4); a service exposed on publication (that is a tenant of `stacks/tenants/vm`); layer 7 routing between several services on one address (one stack per service).

## Design

1. **Instances.** `instance_count` instances spread over `zones` in order, in an anti-affinity server group, booted from the image or a volume, as in `stacks/tenants/vm`. Administration through the bastion of the project (module `bastion`), as there.
2. **Workload.** Input `workload`: what cloud-init adds to each instance, `packages`, `write_files` and `runcmd`, in the form of the tenant module's `modules/cloudinit`. Without it, a demonstration: on each port of the services, an answer with the name of the service and of the instance, over HTTPS when the instance has a certificate, HTTP otherwise, so that the HTTPS checks of the campaign also cover a shared service on virtual machines. The stack does not template the workload: a configuration that depends on the instance (its address, its zone) reads it from the instance metadata.
3. **Service addresses.** Input `services`, as in the shared cluster: for each, its ports, its sources (the consumers by default) and its names (`domains`). One address per service on the internal services plane (ADR-0006, D1): an internal Octavia load balancer in front of the instances when there are several, with a TCP listener and a TCP health monitor per port; the instance's own port when there is one. On a plane with NAT, a floating IP of the plane per address (ADR-0006, D4).
4. **Admission.** `consumers` (CIDRs: the `internal_sources` of the consuming tenants), admitted on the ports of the services only, by the security group of the instances and the allowed CIDRs of the listeners. Empty: closed, as when the service is created before its consumers. SSH from the bastion only.
5. **Names.** `internal_zone` and `dns`, as in the shared cluster (ADR-0016, D2): a record per name of the `domains` of each service, to its address, written in Designate or given in `dns_records` for the adopter's DNS provider.
6. **Certificates.** `certificates`, as in `stacks/tenants/vm` (ADR-0008): each instance obtains a certificate for the domains of the services with lego through DNS-01, written to `/etc/shared-service/tls/` for the workload, renewed by a timer that runs `tls_reload` (a command of the workload); `null` is the demonstration mode, self-signed, with the warning at every plan. The service terminates TLS itself: the load balancer passes TCP through.
7. **Egress.** `egress`: `router` (its own egress router), `shared` (through the shared egress, ADR-0016, D1) or `none` (an image that holds the workload already, without certificates: lego is installed from its release archive).
8. **Outputs.** `services` (each service and its address and ports), `domains`, `dns_records`, `sources` (the service's addresses on each plane, for the admission rules of what it calls), `instances`, `bastion`: the names of the shared cluster's outputs where they mean the same.
9. **`lz`.** Type `vm` accepted for a shared service; `service-<name>` gives it its attachment, the receiver, the certificates and the consumers' `internal_sources`, and waits for its instances. The reference scenario declares `internal` (`type = "vm"`, two instances, two zones when the test cloud has them, consumer `published`), removes `tests/fixtures/internal-service`, and the isolation test reads the address from the `services` output.

## Dependencies and order

Stacked on `lz deploy` (issue #40). Steps, each delivered and tested on its own:

1. The stack, with its `tofu test` mocks (spread over zones, one or several instances, admission, records, demonstration mode) and its README.
2. `lz`: type `vm` for shared services, the example configuration, unit tests.
3. The reference scenario on the stack, the fixture removed, the docs that name it (test procedure, isolation matrix, architecture); a campaign in both modes.

## Proposed decisions

No new ADR: each choice applies a decision already taken to virtual machines.

- One address per service, a load balancer only when there are several instances (ADR-0006, D1), rather than always a load balancer: a single instance costs no amphora, as a `vm` tenant.
- The workload as cloud-init parts, rather than a variable per service type (database, directory): the reference stays at level 2 (ADR-0003); the workload is the adopter's.
- TLS terminated by the service (ADR-0008, D5), the load balancer in TCP: the consumer checks the service's certificate, and a service that is not HTTP (a database, LDAP) gets it too.

## Settled questions

- The demonstration workload: HTTP on 8080, HTTPS when the instance has a certificate (part 2), rather than a TCP echo.
- TLS terminated by the service, the load balancers in TCP (part 6).
- The spread over zones: the test cloud has one availability zone; the spread is tested by the mocks, as for the tenants.
