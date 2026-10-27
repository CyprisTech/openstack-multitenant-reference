# Security policy

## Supported versions

| Version | Supported |
|---|---|
| Latest minor release | Yes |
| Older releases | No — upgrade to the latest minor release |

## Reporting a vulnerability

**Do not open a public issue.** Report privately through GitHub's [private vulnerability reporting](https://github.com/CyprisTech/openstack-multitenant-reference/security/advisories/new). If you cannot use it, email [opensource@cypris-tech.com](mailto:opensource@cypris-tech.com).

Please include:

- the affected version or commit;
- a description of the issue and its impact (for example, a flow the reachability matrix declares denied but that is open, a security group rule broader than documented, a secret written to an unexpected place);
- the steps or configuration that reproduce it, **with all credentials, addresses, domains and names replaced by placeholders**.

Never send state files, plan files, `terraform.tfvars`, `clouds.yaml`, application credentials or real infrastructure details.

## What to expect

| Step | Target |
|---|---|
| Acknowledgement | within 5 business days |
| Initial assessment | within 10 business days |
| Fix or mitigation | depends on severity; critical issues are prioritised |
| Disclosure | coordinated with the reporter, through a GitHub security advisory once a fix is released |

## Scope

In scope: the stacks, the test configurations, the reachability matrix script and the isolation claims of the documentation.

Out of scope: vulnerabilities of the [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant/security) module (report them there), of OpenStack, the OpenStack provider, OpenTofu, Terraform or Traefik (report them to the respective projects), and the way an operator stores state or secrets.

## Security-relevant behaviour of the architecture

- **Isolation on `svc_public` rests on security groups alone.** Every project attached to the plane can reach every published backend at the network level; a wrong rule exposes a backend to every tenant on the plane ([trade-offs, 7](docs/trade-offs.md#7-isolation-on-the-svc_public-plane)).
- **Metrics ports are open to the collector's addresses only** (`monitoring.collector_cidrs`). With `null`, the whole monitoring plane range is admitted, and since tenants join the plane through source NAT, any tenant can then scrape any other.
- **The edge does not terminate TLS.** It holds no tenant certificate; it can only limit connections, not filter HTTP.
- **The demonstration backends are not production services**: the `web` stack serves a self-signed certificate.
- **State files contain secrets** and infrastructure details: treat every state as a secret.
- The reachability matrix only opens TCP connections; it changes nothing, but it uses SSH keys that reach every tenant's bastion. Run it from a trusted machine.
