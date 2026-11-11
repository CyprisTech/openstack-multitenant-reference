# kubernetes-cluster

A Kubernetes cluster created by Cluster API with the OpenStack provider ([ADR-0002](../../docs/adr/0002-platform-kubernetes.md)), in its own project: the cluster network and its routers to the planes, the server groups of the machines, the bootstrap instance, and the Cluster API manifests and scripts written on it. The stacks that deploy a cluster call it: [`stacks/tenants/kubernetes`](../../stacks/tenants/kubernetes/README.md) for a tenant cluster, [`stacks/shared/kubernetes`](../../stacks/shared/kubernetes/README.md) for a cluster of shared services. Every version is pinned in [`cluster.tf`](cluster.tf).

What the module owns of the cluster's lifecycle, and what it leaves to Cluster API: [ADR-0009](../../docs/adr/0009-kubernetes-lifecycle.md).

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
| admission | ../admission | n/a |
| cloudinit | git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit | v0.1.5 |
| planes | ../plane-attachment | n/a |
| tenant | git::https://github.com/CyprisTech/terraform-openstack-tenant.git | v0.1.5 |

### Resources

| Name | Type |
| ---- | ---- |
| [openstack_networking_floatingip_v2.entry](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/resources/networking_floatingip_v2) | resource |
| [terraform_data.checks](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.entries](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [openstack_networking_network_v2.egress](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_network_v2) | data source |
| [openstack_networking_router_v2.plane](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs/data-sources/networking_router_v2) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin | Administration access.<br/>- users: login => SSH public keys, created on the bootstrap instance with sudo.<br/>- sources: addresses of the operators as seen on the administration network (with source NAT,<br/>  the address of a router). They reach the bootstrap instance on port 22 and the Kubernetes<br/>  API on port 6443, and nothing else does.<br/>- ssh\_key\_name: Nova key pair injected in the cluster machines, or null for none. | <pre>object({<br/>    users        = optional(map(list(string)), {})<br/>    sources      = list(string)<br/>    ssh_key_name = optional(string)<br/>  })</pre> | n/a | yes |
| az | Availability zone of the bootstrap instance and of the cluster machines. | `string` | n/a | yes |
| cluster | The Kubernetes cluster created by Cluster API.<br/>- node\_image: name of the image built by images/kubernetes-node.<br/>- kubernetes\_version: must match the node image.<br/>- control\_plane\_count: 3 for a highly available control plane.<br/>- control\_plane\_root\_volume\_size, worker\_root\_volume\_size: GiB of the root volume of each<br/>  machine (container images, ephemeral storage, logs, and etcd on the control plane). They<br/>  must not be smaller than the virtual size of the node image. 0 boots from the flavor's<br/>  local disk instead: faster to create, lost with the machine, no live migration without<br/>  shared storage; the flavor's disk must then be large enough.<br/>- pod\_cidr, service\_cidr: must not overlap the cluster network nor the planes. | <pre>object({<br/>    name                           = string<br/>    node_image                     = string<br/>    kubernetes_version             = optional(string, "v1.36.5")<br/>    control_plane_flavor           = string<br/>    worker_flavor                  = string<br/>    control_plane_count            = optional(number, 3)<br/>    worker_count                   = optional(number, 2)<br/>    control_plane_root_volume_size = optional(number, 30)<br/>    worker_root_volume_size        = optional(number, 40)<br/>    pod_cidr                       = optional(string, "10.244.0.0/16")<br/>    service_cidr                   = optional(string, "10.96.0.0/12")<br/>  })</pre> | n/a | yes |
| egress\_network | External network giving the default route (packages, container images). The cluster gets no public address on it. | `object({ network = string, subnet = string })` | n/a | yes |
| flavor | Flavor name of the bootstrap instance (kind runs there: 2 vCPU and 4 GiB at least). | `string` | n/a | yes |
| image | Image name of the bootstrap instance (an Ubuntu LTS cloud image). | `string` | n/a | yes |
| name | Name of the cluster and prefix of its resources, for example "site-a-published". | `string` | n/a | yes |
| plane\_attachment | The stack's entry of the attachments output of stack shared/planes (attachments.<name>.planes),<br/>keyed by plane: how its router joins each plane and how its instances are seen there,<br/>whatever provides the plane (the operator, or a hub project). | <pre>map(object({<br/>    mode         = string<br/>    nat          = bool<br/>    cidr         = string<br/>    network_id   = string<br/>    network_name = string<br/>    subnet_id    = string<br/>    routes       = optional(list(object({ destination = string, next_hop = string })), [])<br/>  }))</pre> | n/a | yes |
| planes | Keys of the planes the cluster network joins, among those of plane\_attachment. | `list(string)` | n/a | yes |
| site | Short site name; must match the site of the entry point (stack shared/entry-point). | `string` | n/a | yes |
| admin\_network | Administration network carrying the floating IPs of the Kubernetes API and of the bootstrap<br/>instance (ADR-0002, D6). null uses the internal services plane for this role, which requires an<br/>operator plane (gateway mode): then admin.sources must be specific addresses, never the range<br/>of the plane. | `object({ network = string, subnet = string, cidr = string })` | `null` | no |
| boot\_volume\_size | Size in GiB of the root volume of the bootstrap instance; null boots from the flavor's local disk. | `number` | `null` | no |
| bootstrap | Create the bootstrap instance. Set to false once the cluster manages itself (ADR-0002, D3); set back to true before tearing the cluster down. | `bool` | `true` | no |
| certificates | Certificates of the domains of the cluster (ADR-0008): cert-manager obtains and renews them<br/>through the ACME DNS-01 challenge, from any ACME directory (Let's Encrypt, or the<br/>organisation's authority), and writes the secret of the ingress listener. null runs the<br/>demonstration mode: a self-signed certificate, with a warning at every plan.<br/>- directory\_url, ca\_bundle (PEM, for an authority that is not publicly trusted), email.<br/>- dns.provider "rfc2136" with dns.settings nameserver ("host:port"), tsig\_key\_name,<br/>  tsig\_algorithm, tsig\_secret: the stack writes the TSIG secret in the cert-manager<br/>  namespace. Any other provider: dns.solver, a cert-manager dns01 solver, whose credentials<br/>  Secret you create in the cert-manager namespace.<br/>- dns.resolvers: name servers ("host:port") cert-manager checks the TXT record on; empty<br/>  uses the cluster's resolvers.<br/>The settings reach the cluster through the bootstrap instance's user data, readable by the<br/>members of the project: give a key restricted to the \_acme-challenge records of the domains. | <pre>object({<br/>    directory_url = string<br/>    ca_bundle     = optional(string)<br/>    email         = string<br/>    dns = object({<br/>      provider  = string<br/>      settings  = optional(map(string), {})<br/>      solver    = optional(any)<br/>      resolvers = optional(list(string), [])<br/>    })<br/>  })</pre> | `null` | no |
| cluster\_cidr | Range of the cluster network (nodes, load balancer VIPs, bootstrap instance). | `string` | `"10.24.0.0/24"` | no |
| dns\_nameservers | DNS resolvers of the cluster network, reachable through its routes. They must resolve the endpoints of the cloud APIs (Cluster API, the cloud controller manager and Cinder CSI call them from the cluster), and public names for the images. | `list(string)` | `[]` | no |
| ingresses | HTTP entries of the cluster (ADR-0006): each one a Traefik deployment with its own Gateway<br/>and Service, so that a route attached to one cannot be served by another. Keyed by name.<br/>- plane: the plane its address is on: a floating IP of the plane with NAT, the address<br/>  host in the cluster network otherwise (reached through the plane's routes). "egress"<br/>  exposes it directly: a floating IP of egress\_network (ADR-0006, D2).<br/>- sources: who may connect (loadBalancerSourceRanges).<br/>- proxy\_protocol: the sources send a PROXY protocol v2 header (the entry point).<br/>- domains: names served, with a certificate for them.<br/>- namespace: Kubernetes namespace of the Traefik deployment and its Gateway (traefik-<key><br/>  by default); the Gateway is <namespace>-gateway.<br/>- tls\_secret: Secret of the listener's certificate (<key>-tls by default).<br/>- host: host number of the address on a plane without NAT, below reserved\_hosts. | <pre>map(object({<br/>    plane          = string<br/>    sources        = list(string)<br/>    proxy_protocol = optional(bool, false)<br/>    domains        = list(string)<br/>    namespace      = optional(string)<br/>    tls_secret     = optional(string)<br/>    host           = optional(number)<br/>  }))</pre> | `{}` | no |
| monitoring | Monitoring as a push integration point (ADR-0007): the Prometheus of the cluster pushes to<br/>the receiver through the observability plane (remote write). Nothing connects into the cluster<br/>for its metrics.<br/>- receiver: base URL of the receiver, for example "http://192.0.2.10:9090" (output<br/>  receiver\_url of the receiver); null keeps the metrics in the cluster. | <pre>object({<br/>    receiver = optional(string)<br/>  })</pre> | `{}` | no |
| network\_mtu | MTU of the cluster network. It must not exceed the MTU the cloud can carry for tenant<br/>networks, nor the MTU of the planes the network joins (planes contract). The pod network<br/>uses this value minus the VXLAN overhead (ADR-0002, D4). null keeps the cloud default. | `number` | `null` | no |
| reserved\_hosts | Neutron does not allocate the first host numbers of the cluster network to anything else, so<br/>that the addresses of the entries on planes without NAT (their host number) are known before<br/>the cluster exists. | `number` | `32` | no |
| services | Layer 4 entries of the cluster: a Service of type LoadBalancer for a workload you deploy,<br/>selected by labels, at an address prepared like the ingresses' (plane "egress" included).<br/>Keyed by name. | <pre>map(object({<br/>    plane     = string<br/>    namespace = string<br/>    selector  = map(string)<br/>    ports     = list(number)<br/>    sources   = list(string)<br/>    host      = optional(number)<br/>  }))</pre> | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bootstrap | Floating IP of the bootstrap instance on the administration network, or null once it is removed. |
| entries | Address of each entry, keyed like the ingresses and the services inputs: a floating IP of its plane with NAT, its address in the cluster network otherwise. |
| manifests | Rendered Cluster API manifests, as written on the bootstrap instance. Sensitive with certificates (the DNS provider's key). |
| scripts | Rendered create and delete scripts, as written on the bootstrap instance (cloud-init writes them once: copy them again after a change). |
| sources | Addresses the cluster connects from on each plane it joins, for the admission rules of what it calls there (allowed\_sources): its router's gateway address on a plane with NAT, the cluster range on a plane without NAT. |
<!-- END_TF_DOCS -->
