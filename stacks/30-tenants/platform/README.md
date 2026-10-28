# Stack 30 — tenant `platform`

A Kubernetes cluster created by Cluster API with the OpenStack provider (CAPO), published on `svc_public` behind the entry point, federated by the monitoring collector, administered from the administration network only. Design: [ADR-0002](../../../docs/adr/0002-platform-kubernetes.md).

| Created by | What |
|---|---|
| this stack (Terraform) | cluster network and its routers (egress, `svc_public`, `monitoring`, `intranet`, optional administration network), server groups, bootstrap instance, floating IPs of the ingress (`svc_public`) and of Prometheus (`monitoring`), DNS record of Prometheus in the monitoring zone |
| `create-cluster.sh` on the bootstrap instance | kind, Cluster API with CAPO, ORC and CAAPH, then the cluster: 3 control-plane nodes behind the API load balancer, workers, add-ons |
| the add-ons (CAAPH) | Cilium, OpenStack cloud controller manager, Cinder CSI, metrics-server, kubelet-csr-approver, Traefik (Gateway API) and Prometheus, each behind a load balancer that takes the floating IP created by this stack |

Every version is pinned in [`cluster.tf`](cluster.tf).

## Prerequisites

- Stack 20 applied for the same site: the ingress admits the entry point's addresses only, read from its router.
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

Publish the ingress through the entry point with [`scripts/publish-routes.sh`](../../../scripts/publish-routes.sh): the `routes` output of this stack sends the domains of `cluster.domains` to the ingress floating IP, created here before the cluster exists. The collector finds Prometheus by the `prometheus` output, or by the name `<site>-platform-prometheus` in `monitoring.dns_zone`.

The Services request these addresses (`loadBalancerIP`) and keep them when they are deleted (`keep-floatingip`): recreating a Service or the whole cluster changes neither the published route nor the monitoring record. If the requested address is not available, the cloud controller manager silently allocates another one; `kubectl -n traefik get svc traefik` must show the address of `tofu output routes`.

## Checks

```bash
# Demonstration application behind the Gateway API, then the domain routed by the entry point
kubectl apply -f demo/whoami.yaml
curl -k --resolve apps.example.org:443:<public IP of the entry point> https://apps.example.org/

# Reachability matrix with the platform rows (ADR-0002, D8); needs tests/integration/intranet-service
tests/reachability/check.py --key <ssh key> --platform-kubeconfig platform.kubeconfig
```

A guided discovery of the cluster, with real outputs, is in [docs/platform-tour.md](../../../docs/platform-tour.md).

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

`delete-cluster.sh` deletes the `LoadBalancer` Services first (their load balancers belong to the cloud controller manager), moves Cluster API back to a kind cluster, deletes the `Cluster` and waits until its servers and API load balancer are gone. The floating IPs of the Services are kept and destroyed by `tofu destroy` with the rest of the stack.
