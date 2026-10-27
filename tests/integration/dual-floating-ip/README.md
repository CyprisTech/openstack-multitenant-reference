# Integration test — two floating IPs on one port

Checks that one port can carry a floating IP from `svc_public` and another from `monitoring` at the same time, each external network being reached through its own router, as option B of the monitoring access design requires.

- `dfip-target`: floating IP on `svc_public` (module) and on `monitoring` (added beside the module, which supports one floating IP per port in v0.1).
- `dfip-client`: administered through a floating IP on the admin network; tests the target through both planes.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
dns_nameservers = ["9.9.9.9"]
egress_network  = { network = "public", subnet = "public-subnet" }
svc_public      = { network = "svc_public", subnet = "svc_public", cidr = "198.51.100.0/24" }
monitoring      = { network = "monitoring", subnet = "monitoring", cidr = "203.0.113.0/24" }
admin_network   = { network = "intranet", subnet = "intranet", cidr = "192.0.2.0/24" }
ssh_keys        = ["ssh-ed25519 AAAA..."]
VARS
tofu init && tofu apply
ssh debug@<client admin floating IP>
#   then from the client: TCP 22 to the target's svc_public and monitoring floating IPs
tofu destroy
```
