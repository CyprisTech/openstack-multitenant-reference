# Module `bastion`

An optional administration bastion, written once for every stack ([ADR-0001](../../docs/adr/0001-reference-architecture.md), D10). It creates nothing itself: its outputs are fragments of the tenant model of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant), all empty when `bastion` is null.

The bastion has its own small network, whose only router joins an administration network and carries the bastion's floating IP; a second port on the stack's network reaches the stack's instances. The stack's network gets no route to the administration network.

| Output | Use in the stack |
|---|---|
| `existing_networks` | merged into `tenant.existing.networks` (key `admin`) |
| `networks` | merged into `tenant.networks` |
| `security_groups` | merged into `tenant.security_groups`: SSH from `bastion.ssh_cidrs` |
| `instances` | merged into `tenant.instances` |
| `ssh_rules` | merged into the rules of the instances' security group: SSH from the bastion |
