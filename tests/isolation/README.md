# Isolation test

`check.py` turns the [isolation matrix](../../docs/reference/isolation-matrix.md) into a test, to run after every change ([ADR-0003](../../docs/adr/0003-scope-and-boundary.md), D5). It reads the outputs of the deployed stacks, opens TCP connections from inside the tenants and the receiver (through their bastions) and from the machine running the test, asks the receiver which tenants pushed metrics, and compares each result with the expected one. It exits with status 1 if any row differs. It only opens connections and reads the receiver; nothing is changed.

## Prerequisites

- Stacks `shared/entry-point`, `tenants/vm` and `tenants/isolated` applied **with bastions**, and the domains of `vm` published on the entry point (`scripts/publish-domains.sh`).
- The test receiver [`tests/fixtures/receiver`](../fixtures/receiver/README.md) applied, and its `receiver_url` output given to the stacks as `monitoring.receiver`.
- The same SSH user and key on the bastions, the tenant instances and the receiver (`admin.users` of the stacks, `users` of the receiver).

## Usage

```bash
python3 tests/isolation/check.py --stacks stacks --receiver tests/fixtures/receiver \
  --user ops --key ~/.ssh/id_ed25519 \
  [--platform-kubeconfig platform.kubeconfig --intranet-service tests/fixtures/intranet-service]
```

Each row prints the source, the destination, the port, the expected and the actual result. A probe that cannot run (SSH failure) is reported as an error, never as `closed`.
