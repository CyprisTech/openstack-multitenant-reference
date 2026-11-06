# acme-client

The ACME client of an instance ([ADR-0008](../../docs/adr/0008-tenant-certificates.md), D3): lego obtains the certificate of the domains through the DNS-01 challenge, from any ACME directory (Let's Encrypt, or the organisation's authority), renews it from a systemd timer when it is due, installs it where the service expects it, then runs the deploy commands (for example, reload the service).

No resource: its outputs (`write_files`, `runcmd`) are merged into the cloud-init configuration of the instance. The DNS provider settings are written to one file, `/etc/lego/dns.env`, read by the renewal service only. With `certificates = null`, the outputs are empty.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| certificate\_path | Where the deploy hook installs the certificate (PEM, with its chain). | `string` | n/a | yes |
| domains | Names the certificate is for. | `list(string)` | n/a | yes |
| key\_path | Where the deploy hook installs the private key (PEM, mode 0600). | `string` | n/a | yes |
| certificates | Where the certificate comes from (ADR-0008): any ACME directory (Let's Encrypt, or the<br/>organisation's authority), through the DNS-01 challenge. null: no ACME client.<br/>- directory\_url: the ACME directory, for example<br/>  "https://acme-v02.api.letsencrypt.org/directory".<br/>- ca\_bundle: root certificate (PEM) of an authority that is not publicly trusted.<br/>- email: contact of the ACME account.<br/>- dns.provider: a lego DNS provider code, for example "rfc2136".<br/>- dns.settings: for rfc2136, nameserver ("host:port"), tsig\_key\_name, tsig\_algorithm and<br/>  tsig\_secret; for any other provider, its lego environment variables, as documented by lego.<br/>- dns.resolvers: name servers ("host:port") lego checks the TXT record on, and only on;<br/>  empty uses the instance's resolvers and the zone's authoritative servers.<br/>The settings reach the instance through its user data, readable by the members of the<br/>project: give a key restricted to the \_acme-challenge records of these domains. | <pre>object({<br/>    directory_url = string<br/>    ca_bundle     = optional(string)<br/>    email         = string<br/>    dns = object({<br/>      provider  = string<br/>      settings  = map(string)<br/>      resolvers = optional(list(string), [])<br/>    })<br/>  })</pre> | `null` | no |
| deploy\_commands | Commands the deploy hook runs once the certificate and key are installed, for example to reload the service. | `list(string)` | `[]` | no |
| lego\_version | Version of lego installed on the instance (release archive from GitHub), pinned. | `string` | `"5.6.0"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| runcmd | Commands that install lego and start its timer, once the service it serves is installed. |
| write\_files | Files to write, in the shape of the write\_files input of the cloudinit module. |
<!-- END_TF_DOCS -->
