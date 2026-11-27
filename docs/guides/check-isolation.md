# Check the isolation

The isolation test opens a TCP connection for every row of the [isolation matrix](../reference/isolation-matrix.md) — from the Internet, from inside each tenant, from the receiver and from the Kubernetes cluster — asks the receiver which tenants pushed metrics, and compares each result with the expected one. It changes nothing.

## With `lz`

```bash
lz check landing-zone.toml --dry-run   # the rows, without probing
lz check landing-zone.toml
```

`lz` produces the rows from the members of your configuration and the outputs of their stacks ([the rules](../reference/isolation-matrix.md#the-rules-of-every-deployment)), then probes each one from the machine running it and from an instance of each member, through its bastion. A member of type `existing` is a target at the addresses it declares (`probe_addresses`), and a source if it says how to reach it (`probe = { jump, host }`). Rows of your own, such as a database port that only one tenant may reach, go in a file named by `[check] rows`. The rows and their result are kept in `isolation-rows.json` of the work directory.

By hand, with the stacks of the reference scenario: the sections below.

## When to run it

- After the first deployment.
- After every change that can open or close a flow: a new tenant, a new domain, a security group, a plane, a Kubernetes upgrade.
- Before an audit or a review of the isolation: the output lists every flow and its result.

## Prerequisites

- The entry point, the web tenant and the private tenant (two tenants of the `vm` stack, a state each: give the test a file of each one's outputs, `tofu output -json > web.json`) applied **with bastions**, the domains published.
- The test receiver [`tests/fixtures/receiver`](../../tests/fixtures/receiver/README.md), given to the stacks as `monitoring.receiver`: the test reads it to check that every tenant pushed.
- With the published cluster: its kubeconfig, and the internal service it consumes, a [`shared/vm`](../../stacks/shared/vm/README.md) service on port 8080 (`--internal-service`: its directory, or a file of its outputs when it has its own state).
- For the optional rows: the test ACME authority (`--acme tests/fixtures/acme`) and, with the shared cluster (a Kubernetes cluster for shared services) and its demonstrated services applied, its kubeconfig (`--shared-kubeconfig`).
- The same SSH user and key on the bastions, the instances and the receiver.

## Run

```bash
python3 tests/isolation/check.py --stacks stacks --receiver tests/fixtures/receiver \
  --user ops --key ~/.ssh/id_ed25519 \
  --published-kubeconfig published.kubeconfig # with the published cluster
```

Each row prints the source, the destination, the port, the expected and the actual result; the script exits with status 1 if any row differs. A probe that cannot run (SSH failure) is reported as an error, never as `closed`.

## Reading a failure

| Symptom | Likely cause |
|---|---|
| Every "series pushed" row is `no` | The stacks push to another address: check `monitoring.receiver` against the receiver's `receiver_url`, and on hub planes that `shared/planes` was applied again after the tenants |
| One instance's rows fail, its neighbours pass | The instance did not finish its first boot (`cloud-init status`) |
| A row expected `closed` is `open` | A security group or a route is broader than intended: this is the case the test exists for |

Results of the test campaigns: [test results](../concepts/test-results.md).
