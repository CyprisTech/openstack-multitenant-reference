# Boot check of the node image

Starts one instance from the image built by [images/kubernetes-node](../../../images/kubernetes-node/README.md), on the build network (apply `build-network/` first), with a floating IP on the administration network. The instance only gets an SSH key: nothing else is configured.

```bash
tofu init && tofu apply        # terraform.tfvars: cloud, site, az, flavor, image, admin_network, ssh_public_key
ssh ubuntu@<floating_ip> 'echo $SSH_CLIENT; kubeadm version -o short; kubelet --version; containerd --version; crictl --version'
tofu destroy
```

`$SSH_CLIENT` prints the source address under which the operator machine is seen. That is the address to put in the administration sources (`ssh_cidrs`): with source NAT it is the address of a router, not the address of the machine.
