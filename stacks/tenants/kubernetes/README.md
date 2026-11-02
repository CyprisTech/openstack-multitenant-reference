# Tenant type `kubernetes`

A Kubernetes cluster created by Cluster API with the OpenStack provider (CAPO), published on `svc_public` behind the entry point, federated by the monitoring collector, administered from the administration network only. Design: [ADR-0002](../../../docs/adr/0002-platform-kubernetes.md).

| Created by | What |
|---|---|
| this stack (Terraform) | cluster network and its routers (egress, `svc_public`, `monitoring`, `intranet`, optional administration network), server groups, bootstrap instance, addresses of the ingress (`svc_public`) and of Prometheus (`monitoring`) — floating IPs of the planes in gateway mode, fixed addresses of the cluster network in interface mode — and the DNS record of Prometheus in the monitoring zone |
| `create-cluster.sh` on the bootstrap instance | kind, Cluster API with CAPO, ORC and CAAPH, then the cluster: 3 control-plane nodes behind the API load balancer, workers, add-ons |
| the add-ons (CAAPH) | Cilium, OpenStack cloud controller manager, Cinder CSI, metrics-server, kubelet-csr-approver, Traefik (Gateway API) and Prometheus, each behind a load balancer that takes the address prepared by this stack |

Every version is pinned in [`cluster.tf`](cluster.tf).

## Prerequisites

- The shared entry point (`stacks/shared/entry-point`) applied for the same site: the ingress admits the entry point's addresses only, read from its router.
- The node image built by [images/kubernetes-node](../../../images/kubernetes-node/README.md).
- An application credential **dedicated to the cluster**, restricted, with the `member` and `load-balancer_member` roles of the project. Created by the operator, never by Terraform (ADR-0002, D1):

  ```bash
  openstack application credential create platform-cluster \
    --role member --role load-balancer_member --expiration 2027-01-01T00:00:00
  ```

- Resolvers (`dns_nameservers`) that resolve the cloud API endpoints: the controllers call them from the bootstrap instance and from the cluster.
- When the cloud APIs use a private certificate authority, its certificates in a file: `create-cluster.sh` gives them to Cluster API, ORC, the cloud controller manager and Cinder CSI.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars    # adapt
tofu init && tofu apply

# Copy the cluster credential as the clouds.yaml entry "openstack", then create the cluster.
scp clouds.yaml ops@$(tofu output -raw bootstrap):/tmp/clouds.yaml
scp cacert.pem ops@$(tofu output -raw bootstrap):/tmp/cacert.pem      # private CA only
ssh ops@$(tofu output -raw bootstrap) 'sudo install -m 600 /tmp/clouds.yaml /opt/platform/clouds.yaml && sudo install -m 644 /tmp/cacert.pem /opt/platform/cacert.pem; rm -f /tmp/clouds.yaml /tmp/cacert.pem; sudo /opt/platform/create-cluster.sh'
```

The script can be run again after a failure: each step skips what already exists. It ends with `clusterctl move`: the cluster then manages itself, and the kubeconfig is `/opt/platform/<cluster>.kubeconfig` on the bootstrap instance. The bootstrap instance can be removed with `bootstrap = false`; set it back to `true` before deleting the cluster.

Publish the ingress through the entry point with [`scripts/publish-domains.sh`](../../../scripts/publish-domains.sh): the `published_domains` output of this stack sends the domains of `cluster.domains` to the ingress address, known before the cluster exists. The ingress admits the entry point only, by the `edge_sources` input (output `svc_public_sources` of the entry point). The intranet services admit the cluster by its `intranet_sources` output. The collector finds Prometheus by the `prometheus` output, or by the name `<site>-platform-prometheus` in `monitoring.dns_zone`.

The Services request these addresses (`loadBalancerIP`) and keep them when they are deleted (`keep-floatingip`): recreating a Service or the whole cluster changes neither the published route nor the monitoring record. If the requested address is not available, the cloud controller manager silently allocates another one; `kubectl -n traefik get svc traefik` must show the address of `tofu output routes`.

## Checks

```bash
# Demonstration application behind the Gateway API, then the domain routed by the entry point
kubectl apply -f demo/whoami.yaml
curl -k --resolve apps.example.org:443:<public IP of the entry point> https://apps.example.org/

# Reachability matrix with the platform rows (ADR-0002, D8); needs tests/fixtures/intranet-service
tests/isolation/check.py --key <ssh key> --platform-kubeconfig platform.kubeconfig
```

A guided discovery of the cluster, with real outputs, is in [docs/platform-tour.md](../../../docs/guides/kubernetes-tour.md).

## Teardown

```bash
# 1. The bootstrap instance must exist (bootstrap = true) and be admitted on the API again:
#    after the move, the cluster no longer admits it, and it cannot admit itself.
tofu output -json manifests | jq -r '."cluster.yaml"' \
  | sed "s|BOOTSTRAP_SOURCE|$(tofu output -raw bootstrap)/32|" | kubectl --kubeconfig platform.kubeconfig apply -f -

# 2. Delete the cluster from the bootstrap instance, then the stack.
ssh ops@$(tofu output -raw bootstrap) 'sudo /opt/platform/delete-cluster.sh'
tofu destroy
```

If step 1 was skipped, `delete-cluster.sh` stops at once and prints the command to run.

`delete-cluster.sh` deletes the `LoadBalancer` Services first (their load balancers belong to the cloud controller manager), moves Cluster API back to a kind cluster, deletes the `Cluster` and waits until its servers and API load balancer are gone. The floating IPs of the Services (gateway mode) are kept and destroyed by `tofu destroy` with the rest of the stack.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| openstack | ~> 3.2 |

### Providers

| Name | Version |
| ---- | ------- |
| openstack | ~> 3.2 |
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| admission | ../../../modules/admission | n/a |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.3 |
| planes | ../../../modules/plane-attachment | n/a |
| platform | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | 84c898b5d5036296a7cd3496a54e0721ccbc4936 |

### Resources

| Name | Type |
| ---- | ---- |
| [openstack_networking_floatingip_v2.ingress](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/resources/networking_floatingip_v2) | resource |
| [openstack_networking_floatingip_v2.prometheus](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/resources/networking_floatingip_v2) | resource |
| [terraform_data.checks](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [openstack_networking_router_v2.intranet](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_router_v2) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin | Administration access.<br/>- users: login => SSH public keys, created on the bootstrap instance with sudo.<br/>- sources: addresses of the operators as seen on the administration network (with source NAT,<br/>  the address of a router). They reach the bootstrap instance on port 22 and the Kubernetes<br/>  API on port 6443, and nothing else does.<br/>- ssh\_key\_name: Nova key pair injected in the cluster machines, or null for none. | <pre>object({<br/>    users        = optional(map(list(string)), {})<br/>    sources      = list(string)<br/>    ssh_key_name = optional(string)<br/>  })</pre> | n/a | yes |
| az | Availability zone of the bootstrap instance and of the cluster machines. | `string` | n/a | yes |
| cloud | Entry of clouds.yaml used by this stack (the platform project). | `string` | n/a | yes |
| cluster | The Kubernetes cluster created by Cluster API.<br/>- node\_image: name of the image built by images/kubernetes-node.<br/>- kubernetes\_version: must match the node image.<br/>- control\_plane\_count: 3 for a highly available control plane.<br/>- control\_plane\_root\_volume\_size, worker\_root\_volume\_size: GiB of the root volume of each<br/>  machine (container images, ephemeral storage, logs, and etcd on the control plane). They<br/>  must not be smaller than the virtual size of the node image.<br/>- domains: domains served by the ingress and published through the entry point.<br/>- pod\_cidr, service\_cidr: must not overlap the cluster network nor the planes. | <pre>object({<br/>    name                           = optional(string, "platform")<br/>    node_image                     = string<br/>    kubernetes_version             = optional(string, "v1.36.5")<br/>    control_plane_flavor           = string<br/>    worker_flavor                  = string<br/>    control_plane_count            = optional(number, 3)<br/>    worker_count                   = optional(number, 2)<br/>    control_plane_root_volume_size = optional(number, 30)<br/>    worker_root_volume_size        = optional(number, 40)<br/>    domains                        = optional(list(string), ["apps.example.org"])<br/>    pod_cidr                       = optional(string, "10.244.0.0/16")<br/>    service_cidr                   = optional(string, "10.96.0.0/12")<br/>  })</pre> | n/a | yes |
| edge\_sources | Ranges the entry point connects from on svc\_public: output svc\_public\_sources of stack shared/entry-point. Only they may reach the ingress and send a PROXY protocol header. | `list(string)` | n/a | yes |
| egress\_network | External network giving the default route (packages, container images). The cluster gets no public address on it. | `object({ network = string, subnet = string })` | n/a | yes |
| flavor | Flavor name of the bootstrap instance (kind runs there: 2 vCPU and 4 GiB at least). | `string` | n/a | yes |
| image | Image name of the bootstrap instance (an Ubuntu LTS cloud image). | `string` | n/a | yes |
| monitoring | Exposure of the in-cluster Prometheus to the collector (ADR-0002, D5): a load balancer whose<br/>VIP gets a floating IP of the monitoring plane, admitted from collector\_cidrs only.<br/>- collector\_cidrs: addresses of the collector as seen by the platform. An empty list keeps<br/>  Prometheus inside the cluster (no load balancer, no floating IP).<br/>- dns\_zone: zone shared with the project (name with its trailing dot) where the A record<br/>  <site>-platform-prometheus is written for the collector's DNS service discovery; null<br/>  writes no record. | <pre>object({<br/>    collector_cidrs = list(string)<br/>    dns_zone        = optional(string)<br/>  })</pre> | n/a | yes |
| plane\_attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),<br/>keyed by plane: how its router joins each plane and how its instances are seen there,<br/>whatever provides the plane (the operator, or a hub project). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| site | Short site name; must match the site of the entry point (stack shared/entry-point). | `string` | n/a | yes |
| admin\_network | Administration network carrying the floating IPs of the Kubernetes API and of the bootstrap<br/>instance (ADR-0002, D6). null uses the intranet plane for this role, which requires an<br/>operator intranet plane (gateway mode): then admin.sources must be specific addresses, never<br/>the range of the intranet. | `object({ network = string, subnet = string, cidr = string })` | `null` | no |
| boot\_volume\_size | Size in GiB of the root volume of the bootstrap instance; null boots from the flavor's local disk. | `number` | `null` | no |
| bootstrap | Create the bootstrap instance. Set to false once the cluster manages itself (ADR-0002, D3); set back to true before tearing the cluster down. | `bool` | `true` | no |
| cluster\_cidr | Range of the cluster network (nodes, load balancer VIPs, bootstrap instance). | `string` | `"10.24.0.0/24"` | no |
| dns\_nameservers | DNS resolvers of the cluster network, reachable through its routes. They must resolve the endpoints of the cloud APIs (Cluster API, the cloud controller manager and Cinder CSI call them from the cluster), and public names for the images. | `list(string)` | `[]` | no |
| network\_mtu | MTU of the cluster network. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes the network joins (planes contract). The pod network<br/>uses this value minus the VXLAN overhead (ADR-0002, D4). null keeps the cloud default. | `number` | `null` | no |
| service\_addresses | Host numbers, in the cluster network, of the load balancers of the cluster Services on<br/>interface planes: ingress (svc\_public) and prometheus (monitoring). Neutron does not<br/>allocate the first addresses of the cluster network to anything else (reserved below<br/>reserved\_hosts), so these addresses are known before the cluster exists. | <pre>object({<br/>    ingress        = optional(number, 10)<br/>    prometheus     = optional(number, 11)<br/>    reserved_hosts = optional(number, 32)<br/>  })</pre> | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bootstrap | Floating IP of the bootstrap instance on the administration network, or null once it is removed. |
| edge\_sources | Addresses of the entry point admitted by the ingress load balancer. |
| intranet\_sources | Addresses the cluster reaches the intranet from, for the services of the intranet (allowed\_sources): its router's gateway address on an operator plane, the cluster range on an interface plane. |
| manifests | Rendered Cluster API manifests, as written on the bootstrap instance. |
| prometheus | Federation endpoint of the in-cluster Prometheus on the monitoring plane, or null when it is not exposed. |
| published\_domains | Domains served by this tenant and their backends, for the domains input of the entry point (scripts/publish-domains.sh): the platform domains to the ingress (floating IP on svc\_public in gateway mode, load balancer address in interface mode). |
| scripts | Rendered create and delete scripts, as written on the bootstrap instance (cloud-init writes them once: copy them again after a change). |
<!-- END_TF_DOCS -->
