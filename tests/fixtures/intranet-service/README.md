# Intranet demonstration service

An internal service on the intranet plane, for the reachability matrix ([ADR-0002](../../../docs/adr/0002-platform-kubernetes.md), D7): `platform` must reach it, `web` and `isolated` must not. It answers on port 8080 through a floating IP of the intranet, and admits on that port only the address under which `platform` reaches the intranet (its intranet router, read by name). Apply it after the platform stack.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
intranet  = { network = "intranet", subnet = "intranet" }
ssh_cidrs = ["192.0.2.10/32"]
ssh_keys  = ["ssh-ed25519 AAAA..."]
VARS
tofu init && tofu apply
```

Destroy it **before** the platform stack: it reads the platform's intranet router. If the platform stack is already gone, `tofu destroy -refresh=false` skips that lookup.
