# Intranet demonstration service

An internal service, a **shared service of the intranet plane**, for the [isolation test](../../isolation/README.md) ([ADR-0002](../../../docs/adr/0002-platform-kubernetes.md), D7): the Kubernetes tenant must reach it, the other tenants must not. It answers on port 8080 and admits on that port only `allowed_sources`: the `intranet_sources` output of the Kubernetes tenant.

- On an operator plane (gateway mode), it has a floating IP of the intranet, which also carries SSH for the administration sources.
- On an interface plane (`shared/planes`, role `shared` on `intranet`), it is reached at its own address, through the transit router.

```bash
cat > terraform.tfvars <<'VARS'   # git-ignored
cloud = "..."; site = "site-a"; az = "..."; image = "..."; flavor = "..."; boot_volume_size = 8; network_mtu = 1362
allowed_sources = ["198.51.100.7/32"] # intranet_sources output of the Kubernetes tenant
ssh_cidrs       = ["192.0.2.10/32"]
ssh_keys        = ["ssh-ed25519 AAAA..."]
VARS
tofu -chdir=../../../stacks/shared/planes output -json attachments | jq '{plane_attachment: ."intranet-service".planes}' > planes.auto.tfvars.json
tofu init && tofu apply
```

Like any shared service, it runs in its own project, not in the hub project (which holds the network only).
