# ADR-0018: The campaign becomes the deployment tool

- **Status:** Accepted
- **Date:** 2026-11-26
- **Deciders:** maintainers
- **Refines / Supersedes:** refines 0005 (stacks, contracts and access) and 0017 (upgrades between releases)

## Context

The stacks exchange their values through their outputs: a stack's inputs are written from the outputs of the others (`tofu output -json … | jq … > *.auto.tfvars.json`), in an order that the getting started gives, with steps outside Terraform in between (the update of a cluster, the publication of the domains). Seven stacks and some twenty such inputs: an adopter repeats by hand what the test campaign does by itself.

The campaign (`tests/campaign`) already sequences the stacks, wires their outputs to the inputs of the others, updates the clusters with the scripts of the guides, publishes the domains, resumes after an interruption, tears down in waves and checks that nothing is left. It is the only tool of the repository that deploys the reference end to end, and it was presented as a tool for the maintainers.

## Options considered

1. **Keep the campaign a test tool**, and document the manual wiring. The adopter writes their own orchestration; the reference is tested end to end but cannot be deployed end to end without it.
2. **Terragrunt or Terramate** to drive the stacks. Both sequence Terraform stacks and pass values between them, but add a dependency to learn and install, and do not run the steps outside Terraform (cluster updates, domain publication, checks): scripts around them would remain.
3. **A control plane** (Crossplane, operators of our own): continuous reconciliation of the whole landing zone. It turns the reference into a platform product, levels 1 and 3 that [ADR-0003](0003-scope-and-boundary.md) leaves out.
4. **The campaign becomes the deployment tool**, with the tests on top of it. The pattern of public landing zones such as Google Cloud Foundation Fabric's FAST, whose Terraform stages are chained by the files of their outputs.

## Decision

Option 4.

### D1 — One tool, three uses

`lz` (`tools/landing-zone/`, Python standard library, as the campaign today):

- **try**: the reference with its fixtures (receiver, ACME authority, internal service, resolver) on test projects: the working example, in about an hour;
- **deploy**: without fixtures; the adopter's receivers, certificate authority and internal services are given as inputs, with their own tenants;
- **campaign**: try, plus every check, the loads and the recordings: the release campaign of the maintainers, and of an adopter who reproduces the evidence on their cloud.

### D2 — Commands, not sequences of steps

`plan` (each stack's plan, with what it replaces and destroys), `apply`, `status` (what is deployed; the clusters behind their stack), `update-clusters`, `upgrade --from <release>`, `teardown`, `campaign <scenario>`.

### D3 — One configuration file

A TOML file gives the profile, the `clouds.yaml` entry of each stack, the planes, the tenants with their input files, the domains and the state backend. It is validated before anything runs, with messages that say what to fix; a commented example is in `examples/`.

### D4 — Terraform stays the engine; `lz` sequences

`lz` holds no state of its own beyond the Terraform states and its configuration, and passes the adopter's backend through. The stacks stay usable without it: a pipeline, Terragrunt or Terramate can drive them through the contracts of [ADR-0005](0005-stacks-contracts-and-access.md). `lz` is the documented and tested path, not a required one.

### D5 — An orchestrator, not a control plane

`lz` runs on demand; nothing runs between two commands. Drift shows at plan and in `status`. The continuous reconciliation of what runs in the clusters is the GitOps integration point (`v0.8`); of the clusters themselves, Cluster API.

## Consequences

- `tests/campaign` moves to `tools/landing-zone`; the unit tests stay under `tests/`. The release campaign is `lz campaign`.
- The getting started becomes the path of `lz try`; the guides give both ways where a step is run by `lz` (`lz update-clusters`, or the scripts it runs).
- The stacks do not change: no migration note.
- Adding a stack means adding it to `lz`, with its inputs and its place in the order.
