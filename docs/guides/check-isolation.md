# Check the isolation

The isolation test opens a TCP connection for every row of the [isolation matrix](../reference/isolation-matrix.md) — from the Internet, from inside each tenant, from the receiver and from the Kubernetes cluster — asks the receiver which tenants pushed metrics, and compares each result with the expected one. It changes nothing.

## When to run it

- After the first deployment.
- After every change that can open or close a flow: a new tenant, a new domain, a security group, a plane, a Kubernetes upgrade.
- Before an audit or a review of the isolation: the output lists every flow and its result.

## Prerequisites

- The entry point and the `vm` and `isolated` tenants applied **with bastions**, the domains published.
- The test receiver [`tests/fixtures/receiver`](../../tests/fixtures/receiver/README.md), given to the stacks as `monitoring.receiver`: the test reads it to check that every tenant pushed.
- With a Kubernetes tenant: its kubeconfig, and the intranet service it consumes (or the test one, [`tests/fixtures/intranet-service`](../../tests/fixtures/intranet-service/README.md)).
- The same SSH user and key on the bastions, the instances and the receiver.

## Run

```bash
python3 tests/isolation/check.py --stacks stacks --receiver tests/fixtures/receiver \
  --user ops --key ~/.ssh/id_ed25519 \
  --platform-kubeconfig platform.kubeconfig   # with a Kubernetes tenant
```

Each row prints the source, the destination, the port, the expected and the actual result; the script exits with status 1 if any row differs. A probe that cannot run (SSH failure) is reported as an error, never as `closed`.

## Reading a failure

| Symptom | Likely cause |
|---|---|
| Every "series pushed" row is `no` | The stacks push to another address: check `monitoring.receiver` against the receiver's `receiver_url`, and on hub planes that `shared/planes` was applied again after the tenants |
| One instance's rows fail, its neighbours pass | The instance did not finish its first boot (`cloud-init status`) |
| A row expected `closed` is `open` | A security group or a route is broader than intended: this is the case the test exists for |

Results of the test campaigns: [test results](../concepts/test-results.md).
