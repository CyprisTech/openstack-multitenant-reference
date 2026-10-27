# Stack 20 — public entry point

One entry point for every public domain of the site ([ADR-0001](../../docs/adr/0001-reference-architecture.md), D3 and D8):

- an Octavia load balancer with a public floating IP; listeners in **TCP** on 80 and 443, pools in **PROXY** protocol, **TCP** health monitors;
- two Traefik instances on plain VMs, in a server group (anti-affinity), Traefik running as a Podman container started by systemd;
- routes by **SNI with TLS passthrough**, generated from the `routes` variable; PROXY protocol v2 to the backends that accept it;
- routers to the `svc_public` and `monitoring` planes, with their routes pushed by DHCP;
- each Traefik instance exposed to the monitoring collector through a floating IP of the monitoring plane, with an A record in the monitoring zone; node exporter (9100) and Traefik metrics (8082) open to the collector's addresses only (`monitoring`).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # adapt to your cloud
tofu init
tofu apply
```

The stack uses the `cloud` entry of `clouds.yaml` given in `terraform.tfvars`. Make sure no `OS_*` variable is set in the shell: the client would mix it with the `clouds.yaml` entry.

The instances need Internet access at first boot (package index, Podman, Traefik image): `public_network` must provide a default route to the Internet, and `dns_nameservers` must be reachable through it. A resolver that is only reachable on a plane the edge does not join (an intranet resolver, for example) makes the first boot fail and the members stay in `ERROR`.

## Changing the routes

Routes are written by cloud-init, and the module ignores `user_data` changes on existing instances. A change of `routes` takes effect when the instances are replaced, **one at a time**, so that the load balancer keeps one healthy member:

```bash
tofu apply -replace='module.edge.module.instance["SITE-edge-1"].openstack_compute_instance_v2.this'
# wait until the member is ONLINE again: openstack loadbalancer member list SITE-edge-https
tofu apply -replace='module.edge.module.instance["SITE-edge-2"].openstack_compute_instance_v2.this'
```

Connections open on the replaced instance are cut.

## Backends

- `routes.<domain>.backends` take `host:port`. Names must resolve with the `dns_nameservers` of the edge network.
- Backends admit the addresses of the `svc_public_source_ips` output on their published ports. With `proxy_protocol = true` (default), they must expect a PROXY protocol v2 header, from those addresses only.
- Backends terminate TLS and manage their certificates: use DNS-01 or TLS-ALPN-01 challenges ([trade-offs](../../docs/trade-offs.md#1-tls-passthrough-at-the-public-entry-point)).

## Inputs

| Name | Description | Default |
|---|---|---|
| `cloud` | Entry of `clouds.yaml` | required |
| `site` | Short site name used in resource names | required |
| `az`, `image`, `flavor` | Placement and size of the Traefik instances | required |
| `boot_volume_size` | Root volume size in GiB; `null` uses the flavor's disk | `null` |
| `edge_cidr` | Range of the edge network | `10.20.0.0/24` |
| `dns_nameservers` | Resolvers of the edge network | `[]` |
| `network_mtu` | MTU of the stack's networks: smallest of the tenant overlay MTU and the plane MTUs (layer 10 contract) | cloud default |
| `public_network` | External network of the floating IP and default route | required |
| `planes` | `svc_public` and `monitoring`: network, subnet, CIDR (layer 10 contract) | required |
| `octavia_flavor_id` | Octavia flavor (active/standby recommended) | cloud default |
| `server_group_policy` | `anti-affinity` or `soft-anti-affinity` | `anti-affinity` |
| `traefik_image` | Pinned Traefik image | `docker.io/library/traefik:v3.7.16` |
| `routes` | Domains, backends, PROXY protocol, connection limit | `{}` |
| `admin` | SSH users and allowed sources | no access |
| `public_dns` | A records on the floating IP in an existing zone | none |
| `bastion` | Optional bastion with a floating IP on an administration network | none |
| `monitoring` | Monitoring zone for the A records, metrics ports, collector addresses | no record, port 9100 |

## Outputs

| Name | Description |
|---|---|
| `load_balancer` | Virtual IP, floating IP and DNS names |
| `instances` | Traefik instances and their addresses |
| `svc_public_source_ips` | Addresses the edge uses on `svc_public` |
| `routes` | Routed domains |
| `bastion` | Floating IP of the bastion, or null |
| `monitoring_targets` | Floating IP on the monitoring plane and DNS name of each instance |
