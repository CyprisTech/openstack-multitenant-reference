# Isolation test

`check.py` turns the [isolation matrix](../../docs/reference/isolation-matrix.md) into a test, to run after every change ([ADR-0003](../../docs/adr/0003-scope-and-boundary.md), D5). It reads the outputs of the deployed stacks, opens TCP connections from inside the tenants and the receiver (through their bastions) and from the machine running the test, asks the receiver which tenants pushed metrics, and compares each result with the expected one. It exits with status 1 if any row differs. It only opens connections and reads the receiver; nothing is changed.

## Prerequisites

- Stacks `shared/entry-point` and `tenants/vm`, as the web tenant and the private tenant (two workspaces, `--web-workspace`, `--private-workspace`), applied **with bastions**, and the domains of `vm` published on the entry point (`scripts/publish-domains.sh`).
- The test receiver [`tests/fixtures/receiver`](../fixtures/receiver/README.md) applied, and its `receiver_url` output given to the stacks as `monitoring.receiver`.
- The same SSH user and key on the bastions, the tenant instances and the receiver (`admin.users` of the stacks, `users` of the receiver).

## Usage

```bash
python3 tests/isolation/check.py --stacks stacks --receiver tests/fixtures/receiver \
  --user ops --key ~/.ssh/id_ed25519 \
  [--published-kubeconfig published.kubeconfig --internal-service tests/fixtures/internal-service] \
  [--acme tests/fixtures/acme] [--shared-kubeconfig shared.kubeconfig] \
  [--zone example.org [--public-name openstack.org]] [--resolver tests/fixtures/resolver]
```

With `--zone`, every instance must resolve the zone of the landing zone (its SOA) and a public name through the resolvers of its subnet ([ADR-0016](../../docs/adr/0016-network-services-and-edge-by-level.md), D3). With `--resolver`, the private tenant must use the [test resolver](../fixtures/resolver/README.md), behind the internal services plane. There is no row for time: it is a requirement on the cloud, and a wrong clock fails the HTTPS checks, which verify certificates.

Each row prints the source, the destination, the port, the expected and the actual result. A probe that cannot run (SSH failure) is reported as an error, never as `closed`.
