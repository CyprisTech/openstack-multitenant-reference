# Kubernetes lifecycle

What the landing zone requires of a cluster's life ([ADR-0009](../adr/0009-kubernetes-lifecycle.md)). For everything else (scaling, remediation, etcd backups), follow the [Cluster API documentation](https://cluster-api.sigs.k8s.io/tasks/). The commands run from an administration source admitted on the API, with the kubeconfig of the cluster; the bootstrap instance is not needed.

## Update a cluster after an apply

The manifests and scripts of a cluster reach its bootstrap instance once, at creation. After `clusterctl move` the cluster manages itself: an apply of its stack that changes them (a new release, new consumers, another Kubernetes version) reaches it through `update-cluster.sh`, run from an administration source with the cluster's kubeconfig ([ADR-0017](../adr/0017-upgrades-between-releases.md), D3). From the root of the repository:

```bash
tofu -chdir=stacks/tenants/kubernetes apply
scripts/cluster-files.sh stacks/tenants/kubernetes ~/published      # the scripts and manifests outputs
KUBECONFIG=~/published.kubeconfig ~/published/update-cluster.sh
```

The script applies, in order:

1. the objects of the cluster that are not Helm charts: cloud configuration (when a `clouds.yaml` is in the directory), right of the cloud controller to delete nodes, storage class, Gateway API resources, ingress namespaces, services;
2. the Cluster API providers, upgraded with `clusterctl upgrade apply` when the release changes their versions, and ORC;
3. the ClusterClass, the add-ons and the node image. A change of a machine gives templates of a new name: Cluster API replaces the machines one by one, so the project needs room for one more of each;
4. the certificates of the domains;
5. a check of one Helm release proxy per chart;
6. the `Cluster` object, then it waits until the cluster is available.

It can be run again. With certificates, the manifests hold the key of the DNS provider: `cluster-files.sh` writes them readable by their owner only.

## Upgrade Kubernetes

A Kubernetes version needs its node image. The service addresses and the address of the API do not change.

1. Build the image of the new version ([images/kubernetes-node](../../images/kubernetes-node/README.md)) and make it available in the project of the cluster. One minor version at a time.
2. Write the new `kubernetes_version` and `node_image` in the `cluster` input of the stack, apply it, and [update the cluster](#update-a-cluster-after-an-apply). Cluster API replaces the control plane, then the workers, one machine at a time:

   ```bash
   kubectl get nodes -w
   ```

3. Run the [isolation test](check-isolation.md).

## Rotate the credential of the cluster

The cluster holds its application credential in two secrets: one for Cluster API, in `platform`, one for the cloud controller manager and Cinder CSI, in `kube-system`.

1. Have a new application credential created, with the same roles.
2. Write it as the entry `openstack` of a `clouds.yaml` in the directory of the cluster's files (with `cacert.pem` for a private certificate authority), and run `update-cluster.sh` ([update a cluster](#update-a-cluster-after-an-apply)): it replaces both secrets, then restarts the cloud controller manager and Cinder CSI, which read the second one.
3. Check it works: create an internal Service of type `LoadBalancer` (annotation `service.beta.kubernetes.io/openstack-internal-load-balancer: "true"`, `loadBalancerSourceRanges` within the cluster network: outside its entries, the cluster admits no other load balancer), wait for its address, delete it. Then revoke the old credential.

Then delete the `clouds.yaml` of the directory. Also replace `/opt/platform/clouds.yaml` on the bootstrap instance, if there is one, before using it to delete the cluster.

## Delete a cluster

For either cluster: `S=stacks/tenants/kubernetes` (the published cluster) or `S=stacks/shared/kubernetes` (the shared cluster), with its kubeconfig. The bootstrap instance deletes the cluster: set `bootstrap = true` in the stack and apply if it was removed.

```bash
# 1. The bootstrap instance must be admitted on the API again: after the move, the cluster
#    no longer admits it, and it cannot admit itself.
B=$(tofu -chdir=$S output -raw bootstrap)
scripts/cluster-files.sh $S ~/cluster   # from the root of the repository
KUBECONFIG=cluster.kubeconfig ~/cluster/update-cluster.sh --admit "$B/32"
sleep 60   # the API load balancer takes the new source

#    If the creation stopped before the move, Cluster API still runs on the bootstrap instance:
#    skip this step, delete-cluster.sh deletes the cluster from there.

# 2. Delete the cluster from the bootstrap instance, then the stack.
ssh ops@$B 'sudo /opt/platform/delete-cluster.sh'
tofu -chdir=$S destroy
```

If step 1 was skipped, `delete-cluster.sh` stops at once and prints the command to run. A bootstrap instance kept since an earlier release still has that release's scripts, written by cloud-init when it was created: copy the current ones (`cluster-files.sh`) to its `/opt/platform` first.

`delete-cluster.sh` deletes the `LoadBalancer` Services first (their load balancers belong to the cloud controller manager), moves Cluster API back to a kind cluster, deletes the `Cluster` and waits until its servers and API load balancer are gone. The floating IPs of the Services (gateway mode) are kept and destroyed by `tofu destroy` with the rest of the stack.
