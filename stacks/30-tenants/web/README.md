# Stack 30 — tenant `web`

Two web instances serving several domains, published on the `svc_public` plane and reachable only from the public entry point ([ADR-0001](../../../docs/adr/0001-reference-architecture.md), D5 and D7):

- two VMs in a server group (anti-affinity), each with a floating IP on `svc_public`;
- HTTPS admitted only from the addresses of the entry point on `svc_public`, read from its router by name (`<site>-edge-svc-public`): the stack of the entry point must be applied first;
- routers to the egress network (default route), `svc_public` and `monitoring`, with plane routes pushed by DHCP;
- an optional bastion for administration.

The web server is a demonstration backend: nginx terminates TLS with a self-signed certificate, accepts the PROXY protocol v2 header from the entry point only, and answers with the host, the server name and the client address it received.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

The stack uses the `cloud` entry of `clouds.yaml` given in `terraform.tfvars`. Make sure no `OS_*` variable is set in the shell.

## Publishing the domains on the entry point

The `routes` output has the shape of the `routes` variable of stack 20. Generate it, then roll the entry point instances one at a time (see the [stack 20 README](../../20-public-edge/README.md#changing-the-routes)):

```bash
tofu output -json routes \
  | jq '{routes: .}' > ../../20-public-edge/routes.auto.tfvars.json   # git-ignored
```

No address is written by hand (ADR-0001, D9).

## Requirements

- **MTU.** Set `network_mtu` to the smallest of the tenant overlay MTU and the plane MTUs (layer 10 contract). A larger value lets TCP connections open but drops large packets: the TLS handshake then hangs.
- **Range.** `web_cidr` must avoid the ranges reserved by the cloud (layer 10 contract).
- **Internet access at first boot.** The egress network must route to the Internet and the resolvers must be reachable through it (package installation).

## Bastion

With `bastion` set, the stack creates a small network whose only router joins the administration network, and a bastion with a floating IP on it and a second port on the web network. SSH to the web instances is admitted from the bastion only. The second interface ignores the routes and resolvers pushed by DHCP, so the bastion keeps a single default route.

```bash
ssh -J ops@<bastion floating IP> ops@<web instance address>
```

## Outputs

| Name | Description |
|---|---|
| `routes` | Routes for the entry point (stack 20, variable `routes`) |
| `backends` | Published backends, `address:443` on `svc_public` |
| `edge_sources` | Addresses of the entry point admitted on port 443 |
| `instances` | Web instances and their private addresses |
| `bastion` | Floating IP of the bastion, or null |
