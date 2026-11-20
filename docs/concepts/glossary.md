# Glossary

The main terms are in the [README](../../README.md#terms); these are the others.

| Term | Meaning |
|---|---|
| Service address | The address through which a tenant exposes a service; the domains it serves are published to it |
| Ingress | A cluster's entry for HTTP traffic: Traefik as a Gateway API controller, behind a load balancer at an address prepared by the stack. Applications attach `HTTPRoute`s to its `Gateway`; the Kubernetes `Ingress` object is not used |
| Integration point | Where a platform service of your choice (metrics, logs, backups…) plugs in: plane, flows, admission, what each stack configures |
| Region | A set of OpenStack services with its own endpoints. A project is not tied to a region; its resources and the planes are. Each region has its own planes, hub and entry point; an encrypted overlay joins the hubs of several regions |
| Site | The name of a region in a deployment, an input of every stack and part of every name |
| Cloud operator | Who runs the OpenStack cloud: the provider, or your own infrastructure team |
| Administrators | The team that deploys and runs the stacks of this reference. They alone are admitted on the bastions and the Kubernetes APIs, from the addresses declared in the inputs of each stack (`admin`, `bastion.ssh_cidrs`); see [administration paths](architecture.md#administration-paths) |
