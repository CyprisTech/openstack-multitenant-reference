# metrics-agent

The metrics agent of an instance ([ADR-0007](../../docs/adr/0007-monitoring.md), D2): Prometheus in agent mode reads the local exporters and pushes the series to the receiver of the shared services, with labels that identify the source. Nothing connects into the instance for its metrics.

No resource: its outputs (`packages`, `write_files`, `runcmd`) are merged into the cloud-init configuration of the instance. With `receiver = null`, only the node exporter is installed.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| labels | Labels added to every series, identifying the source (for example site, tenant, instance): with address translation, the receiver cannot tell instances apart by their address. | `map(string)` | `{}` | no |
| receiver | Base URL of the receiver, for example "http://192.0.2.10:9090": the agent pushes to <receiver>/api/v1/write. null: no agent. | `string` | `null` | no |
| scrape\_interval | Interval between two readings of the local endpoints. | `string` | `"30s"` | no |
| targets | Local endpoints to read, by job name, for example { node = ["localhost:9100"] }. | `map(list(string))` | <pre>{<br/>  "node": [<br/>    "localhost:9100"<br/>  ]<br/>}</pre> | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| packages | Packages to install: the node exporter, and Prometheus when an agent pushes. |
| runcmd | Commands that start the agent once its package is installed. |
| write\_files | Files to write, in the shape of the write\_files input of the cloudinit module. |
<!-- END_TF_DOCS -->
