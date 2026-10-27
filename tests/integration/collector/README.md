# Test collector

A small instance standing for the monitoring collector, used by the [reachability matrix](../../reachability/README.md). It reaches the monitoring plane through its own router with source NAT, so the tenants see one known source address: the router's gateway address on the plane, exported as `collector_cidrs` and given to the tenant stacks as `monitoring.collector_cidrs`. It is administered through a floating IP on an administration network, whose router is its default gateway.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
monitoring_plane = { network = "monitoring", subnet = "monitoring", cidr = "203.0.113.0/24" }
admin_network    = { network = "intranet", subnet = "intranet" }
ssh_cidrs        = ["192.0.2.0/24"]
ssh_keys         = ["ssh-ed25519 AAAA..."]
VARS
tofu init && tofu apply
tofu output -json collector_cidrs
```
