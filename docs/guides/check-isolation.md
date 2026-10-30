# Check the isolation

The isolation test opens a TCP connection for every row of the [isolation matrix](../reference/isolation-matrix.md) — from the Internet, from inside each tenant, from the collector and from the Kubernetes cluster — and compares each result with the expected one. It changes nothing.

## When to run it

- After the first deployment.
- After every change that can open or close a flow: a new tenant, a new domain, a security group, a plane, a Kubernetes upgrade.
- Before an audit, or when a customer asks how its isolation is verified: the output lists every flow and its result.

## Prerequisites

- The entry point and the `vm` and `isolated` tenants applied **with bastions**, the routes published.
- A collector whose address is in `monitoring.collector_cidrs` of the stacks: yours, or the test collector [`tests/fixtures/collector`](../../tests/fixtures/collector/README.md).
- With a Kubernetes tenant: its kubeconfig, and the intranet service it consumes (or the test one, [`tests/fixtures/intranet-service`](../../tests/fixtures/intranet-service/README.md)).
- The same SSH user and key on the bastions, the instances and the collector.

## Run

```bash
python3 tests/isolation/check.py --stacks stacks --collector tests/fixtures/collector \
  --user ops --key ~/.ssh/id_ed25519 \
  --platform-kubeconfig platform.kubeconfig   # with a Kubernetes tenant
```

Each row prints the source, the destination, the port, the expected and the actual result; the script exits with status 1 if any row differs. A probe that cannot run (SSH failure) is reported as an error, never as `closed`.

## Reading a failure

| Symptom | Likely cause |
|---|---|
| Every collector row fails | The collector's address changed and the stacks still admit the old one: update `monitoring.collector_cidrs` and apply |
| One instance's rows fail, its neighbours pass | The instance did not finish its first boot (`cloud-init status`) |
| A row expected `closed` is `open` | A security group or a route is broader than intended: this is the case the test exists for |

Results of the test campaigns: [test results](../concepts/test-results.md).
