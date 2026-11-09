# Kubernetes lifecycle

What the landing zone requires of a cluster's life ([ADR-0009](../adr/0009-kubernetes-lifecycle.md)). For everything else (scaling, remediation, etcd backups), follow the [Cluster API documentation](https://cluster-api.sigs.k8s.io/tasks/). The commands run from an administration source admitted on the API, with the kubeconfig of the cluster; the bootstrap instance is not needed.

## Upgrade Kubernetes

A Kubernetes version needs its node image. The service addresses and the address of the API do not change.

1. Build the image of the new version ([images/kubernetes-node](../../images/kubernetes-node/README.md)) and make it available in the project of the cluster. One minor version at a time.
2. Declare it in the cluster. The object name is the image name in lower case, with hyphens instead of dots:

   ```bash
   image=ubuntu-2404-kube-v1.36.5; object=$(tr '[:upper:].' '[:lower:]-' <<<"$image")
   kubectl -n platform get image.openstack.k-orc.cloud -o json \
     | jq --arg name "$object" --arg image "$image" '.items[0] | {apiVersion, kind, metadata: {name: $name, namespace: .metadata.namespace}, spec: (.spec | .import.filter.name = $image)}' \
     | kubectl apply -f -
   kubectl -n platform wait image.openstack.k-orc.cloud "$object" --for=condition=Available --timeout=10m
   ```

3. Change the version and the image. Cluster API replaces the control plane, then the workers, one machine at a time; the project needs room for one more of each:

   ```bash
   kubectl -n platform patch cluster <cluster> --type=json -p '[
     {"op": "replace", "path": "/spec/topology/version", "value": "v1.36.5"},
     {"op": "replace", "path": "/spec/topology/variables/1/value", "value": "'"$object"'"}]'
   kubectl get nodes -w
   ```

4. Write the same `kubernetes_version` and `node_image` in the `cluster` input of the stack, so that its manifests describe the cluster, and run the [isolation test](check-isolation.md).

## Rotate the credential of the cluster

The cluster holds its application credential in two secrets: one for Cluster API, in `platform`, one for the cloud controller manager and Cinder CSI, in `kube-system`.

1. Have a new application credential created, with the same roles.
2. Replace the secret of Cluster API: `clouds.yaml`, with the entry named `openstack`, in the secret named by `spec.identityRef` of the `OpenStackCluster`.
3. Replace `application-credential-id` and `application-credential-secret` in the `cloud.conf` key of the secret `kube-system/cloud-config`.
4. Restart what reads it:

   ```bash
   kubectl -n kube-system get deployment,daemonset -o name | grep -E 'cloud-controller|csi' | xargs kubectl -n kube-system rollout restart
   ```

5. Check it works: create a Service of type `LoadBalancer`, wait for its address, delete it. Then revoke the old credential.

Also replace `/opt/platform/clouds.yaml` on the bootstrap instance, if there is one, before using it to delete the cluster.
