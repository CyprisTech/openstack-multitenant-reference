# Contributing

Thank you for considering a contribution. This guide explains how to check a change, how the stacks are tested on a real cloud, and how changes are reviewed.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug** or **request a feature** with the [issue templates](https://github.com/CyprisTech/openstack-multitenant-reference/issues/new/choose). Problems of the module itself belong to [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant/issues).
- **Report test results** on another OpenStack cloud or distribution: what passed, what failed, which part of the [planes contract](docs/reference/planes-contract.md) was hard to meet.
- **Improve the documentation**: unclear explanations, missing trade-offs, wrong statements.
- **Submit code**: open an issue first for anything larger than a small fix, so the design can be agreed before you invest time. A change to the architecture (a design area, the planes, the flows, the isolation matrix) needs an [ADR](docs/adr/README.md) and an entry in the [trade-offs](docs/concepts/trade-offs.md).

## Repository layout

| Path | Content |
|---|---|
| `stacks/shared/planes` | The planes: adopted from the cloud operator, or built in a hub project |
| `stacks/shared/entry-point` | The shared public entry point |
| `stacks/tenants/vm`, `stacks/tenants/isolated`, `stacks/tenants/kubernetes` | The tenant types |
| `modules/` | Building blocks of the stacks: joining a plane, admission rules, bastion, metrics agent, discovery and range checks of `shared/planes` |
| `images/kubernetes-node` | The node image of the Kubernetes tenant |
| `examples/planes` | Configurations of `shared/planes` |
| `scripts/` | Domain publication |
| `tests/isolation` | The isolation test |
| `tests/fixtures/receiver`, `tests/fixtures/intranet-service` | Stand-ins for your platform services, used by the tests and the isolation test |
| `docs/` | Architecture specification, trade-offs, ADRs, test results |

Every directory under `stacks/`, `tests/fixtures/` and `tests/integration/` is a root configuration with its own state. The modules under `modules/` compose those of [terraform-openstack-tenant](https://github.com/CyprisTech/terraform-openstack-tenant), pinned by tag.

## Development setup

| Tool | Purpose | Version |
|---|---|---|
| [OpenTofu](https://opentofu.org/docs/intro/install/) and/or [Terraform](https://developer.hashicorp.com/terraform/install) | validate, deploy | >= 1.9 |
| [TFLint](https://github.com/terraform-linters/tflint) | lint | latest |
| Python | isolation test (standard library only) | >= 3.9 |
| [terraform-docs](https://terraform-docs.io) | inputs and outputs tables of the READMEs | 0.24 |
| [gitleaks](https://github.com/gitleaks/gitleaks) | detect secrets | latest |
| `jq`, `ssh` | domain publication, isolation test probes | any |

## Checks

Run the same checks as CI before pushing. They need no cloud and no credentials:

```bash
tofu fmt -check -recursive                     # or: terraform fmt -check -recursive
for d in stacks/shared/* stacks/tenants/* tests/fixtures/* modules/* tests/integration/*; do
  tofu -chdir="$d" init -backend=false -input=false && tofu -chdir="$d" validate
done
tflint --init
for d in modules/* stacks/shared/* stacks/tenants/*; do
  tflint --chdir="$d" --config="$PWD/.tflint.hcl"
done
for d in tests/fixtures/*/ tests/integration/*/; do
  tflint --chdir="$d" --config="$PWD/tests/integration/.tflint.hcl"
done
python3 -m py_compile tests/isolation/check.py
gitleaks git --no-banner --redact
```

## Testing on a real cloud

**Test policy.** A change that adds a flow, a plane or a tenant type adds the matching rows to the isolation test, with the expected result; a fix of a finding adds the check that would have caught it.

CI only validates the code. Every change to a stack is also tested by the maintainers on a real OpenStack cloud before it is merged, and the results are recorded in the [test results](docs/concepts/test-results.md):

1. **Apply**, then **plan again: the plan after apply must be empty.**
2. Functional checks of the change (for example HTTPS through the entry point, the publication of a domain without interruption).
3. **The isolation test.** [`tests/isolation/check.py`](tests/isolation/README.md) reads the outputs of the deployed stacks and of the [test receiver](tests/fixtures/receiver/README.md), opens TCP connections from inside each tenant and the receiver (through their bastions) and from the machine running the test, asks the receiver which tenants pushed metrics, and compares each result with the expected one. It exits with status 1 if any row differs; a probe that cannot run is an error, never `closed`. It needs the stacks applied **with bastions**, the domains of `vm` published on the entry point, and the receiver's `receiver_url` given to the stacks as `monitoring.receiver`.
4. **Destroy**, and check that nothing is left (instances, load balancers, floating IPs, DNS records).

Use a dedicated, disposable project and project-scoped credentials (an application credential with the `member` role, plus `load-balancer_member` if your Octavia policy requires it). These tests create real resources and may cost money on a public cloud. Contributors are not required to run them; if you do, attach a summary without addresses or names to the pull request.

A change that adds or removes a flow must update the matrix in both places: the [isolation matrix](docs/reference/isolation-matrix.md) and the rows of `check.py`.

## Conventions

These rules come from [ADR-0005](docs/adr/0005-stacks-contracts-and-access.md):

- **One state and one credential per stack; no remote state.** What a stack needs from another is an output of the latter, passed as an input; no stack reads an object of another project.
- **The site is an input** of every stack and part of every name. **No address is written by hand**: routes, admission rules and DNS records are generated from stack outputs.
- **The planes are described once, by `stacks/shared/planes`.** Every other stack takes its `plane_attachment`; a new requirement on the cloud operator's planes is added to the [planes contract](docs/reference/planes-contract.md).
- **No real identifiers.** Domains are `example.org`, addresses are documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`), names are generic. This applies to code, examples, tests, documentation and commit messages.
- **Pinned versions.** The module by tag (`?ref=vX.Y.Z`), container images by version.
- **Documented code.** Every variable and output of a stack has a `description` (TFLint enforces it). Comments explain **why**, only where the code would surprise a reader.
- **Formatting.** `tofu fmt`; two-space indentation.

## Commits

- One logical change per commit.
- Subject in the imperative mood, at most 72 characters (`Add a health check port to the edge`, not `added port`).
- A body that explains **why** the change is needed when it is not obvious.
- Disclose AI assistance with an `Assisted-by:` trailer (for example `Assisted-by: Claude`). Do not use `Co-Authored-By:` for AI tools: GitHub credits it as a co-author.
- **Never commit** state files, plan files, `terraform.tfvars` or any `*.tfvars` other than `*.tfvars.example`, `*.auto.tfvars.json` (generated routes), or `*_override.tf` files (local module overrides). `.gitignore` blocks them; do not force-add them.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change with its documentation (stack README, `terraform.tfvars.example`, matrix, changelog entry under *Unreleased*).
3. Open a pull request and fill in the template.
4. CI must pass on OpenTofu and Terraform.
5. A maintainer reviews the change and, for a change to a stack, runs it on the test cloud.

## Release process

Maintainers tag releases from `main` following [Semantic Versioning](https://semver.org/):

1. Move the *Unreleased* entries of [CHANGELOG.md](CHANGELOG.md) under the new version with its date.
2. Tag `vX.Y.Z` and publish a GitHub release with the changelog section.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
