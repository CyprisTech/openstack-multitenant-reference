# Kubernetes node image

Private image of the `platform` project, built with [image-builder](https://github.com/kubernetes-sigs/image-builder) and its OpenStack builder (Packer) — [ADR-0002](../../docs/adr/0002-platform-kubernetes.md), D1. The image outlives the cluster: it has its own build network and its own state.

| Pinned | Version | Where |
|---|---|---|
| image-builder | v0.1.55 | `build.sh` |
| Kubernetes | v1.36.5 (supported by Cluster API v1.14) | `kubernetes.json` |
| crictl | 1.36.0 | `kubernetes.json` |
| Base OS | Ubuntu 24.04 | `build.sh` (target `build-openstack-ubuntu-2404`) |

## How it works

1. `build-network/` (OpenTofu or Terraform) creates a small network with two routers: one to an egress network (default route, packages and container images), one to the administration network, which carries the floating IP Packer connects to. Only the administration sources are routed through it, and a security group admits SSH from them only.
2. `build.sh` reads the outputs, starts a temporary instance, provisions it with Ansible, and turns it into a private image named `ubuntu-2404-kube-v1.36.5`. The temporary instance, its volume and its floating IP are deleted by Packer.

## Usage

```bash
cd build-network
cp terraform.tfvars.example terraform.tfvars   # adapt
tofu init && tofu apply
cd ..
cp build.json.example build.json               # source image, flavor, volume
OS_CLOUD=<entry of the platform project> ./build.sh
```

To find the address under which the machine running Packer is seen, use the boot check in [tests/integration/node-image](../../tests/integration/node-image/README.md) (`$SSH_CLIENT`): through source NAT it is a router address, which is easy to guess wrong.

Then destroy the build network (`tofu destroy` in `build-network/`); the image stays.
