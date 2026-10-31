# Test collector

A small instance standing for the monitoring collector, a **shared service of the monitoring plane**, used by the [isolation test](../../isolation/README.md). The tenants admit it by the addresses of its `collector_cidrs` output, given to every tenant stack as `monitoring.collector_cidrs`:

- on an operator plane (gateway mode), its router reaches the plane with source NAT: one known address, the router's gateway address;
- on an interface plane (`shared/planes`, role `shared` on `monitoring`), no translation: the collector's own range (`cidr`), routed to every tenant through the transit router.

It is administered through a floating IP on an administration network, whose router is its default gateway. Create it **before** the tenant stacks, which need `collector_cidrs`.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
admin_network = { network = "intranet", subnet = "intranet" }
ssh_cidrs     = ["192.0.2.0/24"]
ssh_keys      = ["ssh-ed25519 AAAA..."]
VARS
tofu -chdir=../../../stacks/shared/planes output -json attachments | jq '{plane_attachment: ."collector".planes}' > planes.auto.tfvars.json
tofu init && tofu apply
tofu output -json collector_cidrs
```

Like any shared service, it runs in its own project, not in the hub project (which holds the network only).
