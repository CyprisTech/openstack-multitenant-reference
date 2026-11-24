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
2. Write it as the entry `openstack` of a `clouds.yaml` in the directory of the cluster's files (with `cacert.pem` for a private certificate authority), and run `update-cluster.sh` ([update a cluster](#update-a-cluster-after-an-apply)): it replaces both secrets.
3. Restart what reads the secret of `kube-system`:

   ```bash
   kubectl -n kube-system get deployment,daemonset -o name | grep -E 'cloud-controller|csi' | xargs kubectl -n kube-system rollout restart
   ```

4. Check it works: create a Service of type `LoadBalancer`, wait for its address, delete it. Then revoke the old credential.

Then delete the `clouds.yaml` of the directory. Also replace `/opt/platform/clouds.yaml` on the bootstrap instance, if there is one, before using it to delete the cluster.
