# Stack 30 — tenant `isolated`

A workload with no public exposure and no path to the other tenants ([ADR-0001](../../../docs/adr/0001-reference-architecture.md), D5):

- one network whose **only router** joins the monitoring plane: it carries the instance's floating IP on that plane and the replies to the collector;
- no egress network, no route to `svc_public` or to the Internet;
- metrics open to the collector only (`monitoring.collector_cidrs`), with an A record in the monitoring zone for DNS service discovery;
- an optional bastion for administration.

The workload is a stand-in: a metrics endpoint served by the Python standard library, so that the instance needs no package and no Internet access.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

## Why the metrics are open to the collector only

Every tenant that joins the monitoring plane does so through a router with source NAT: seen from the plane, all tenants have addresses in the plane range. Opening the metrics ports to the whole range would let any tenant scrape any other. `monitoring.collector_cidrs` restricts them to the collector's addresses; with `null`, the whole plane range is admitted.

## Outputs

| Name | Description |
|---|---|
| `monitoring_targets` | Floating IP on the monitoring plane and DNS name of the instance |
| `instances` | The instance and its private address |
| `bastion` | Floating IP of the bastion, or null |
