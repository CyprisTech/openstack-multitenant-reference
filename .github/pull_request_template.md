## What and why

<!-- What does this change do, and why is it needed? Link the issue: "Closes #123". -->

## Type of change

- [ ] Bug fix
- [ ] New or changed behaviour of a stack (inputs, outputs, resources)
- [ ] Architecture change (an ADR is added or updated)
- [ ] Documentation or tooling only

## Checklist

- [ ] `fmt`, `validate` and `tflint` pass locally on every changed configuration
- [ ] Tested on an OpenStack cloud (apply, empty plan after apply, destroy), or not applicable
- [ ] The reachability matrix (`docs/architecture.md` and `tests/reachability/check.py`) is updated if a flow changed
- [ ] Stack READMEs and `terraform.tfvars.example` updated if inputs or outputs changed
- [ ] `CHANGELOG.md` updated under *Unreleased*
- [ ] No state, plan, `*.tfvars`, `*_override.tf`, credentials or real infrastructure details (domains, addresses, network names) in the diff
