# Isolation test

`check.py` turns the [isolation matrix](../../docs/reference/isolation-matrix.md) into a test, to run after every change ([ADR-0001](../../docs/adr/0001-reference-architecture.md), D6). It reads the outputs of the deployed stacks, opens TCP connections from inside the tenants (through their bastions), from the collector and from the machine running the test, and compares each result with the expected one. It exits with status 1 if any row differs. It only opens connections; nothing is changed.

## Prerequisites

- Stacks `shared/entry-point`, `tenants/vm` and `tenants/isolated` applied **with bastions**, and the domains of `web` published on the entry point (`scripts/publish-domains.sh`).
- The test collector [`tests/fixtures/collector`](../fixtures/collector) applied, and its `collector_cidrs` output given to the three stacks as `monitoring.collector_cidrs`.
- The same SSH user and key on the bastions, the tenant instances and the collector (`admin.users` of the stacks, `ssh_keys` of the collector).

## Usage

```bash
python3 tests/isolation/check.py --stacks stacks --collector tests/fixtures/collector \
  --user ops --key ~/.ssh/id_ed25519
```

Each row prints the source, the destination, the port, the expected and the actual result. A probe that cannot run (SSH failure) is reported as an error, never as `closed`.
