# Spec: campaign tooling by profile

- **Status:** In progress: steps 1 to 3 delivered (private cloud scenario passed in both plane modes on 2026-11-19, Bash removed); the public cloud campaign remains
- **Related:** [ADR-0014](../adr/0014-profiles.md) (profiles, a campaign per profile), [test procedure](../reference/test-procedure.md), [`tests/campaign`](../../tests/campaign/README.md), [isolation test](../guides/check-isolation.md)

## Problem

`tests/campaign` ran the whole scenario from empty projects to an empty teardown, about 1,000 lines of Bash. It worked, but:

- The sequences, the inputs of each stack and the steps are mixed: a step builds its own inputs from environment variables. A second scenario, the public cloud profile, would copy most of it.
- Errors are easy to lose: `errexit` stopped a step on a first SSH attempt; the status of a pipeline is the status of its last command.
- Results are read back from text (`47/47 rows`, `85 ok, 0 failed`) and copied by hand into the [test results](../concepts/test-results.md).
- Every retry and wait loop is written again, with its own delay.
- Nothing can be checked without a cloud: a change of the tooling is only proven by a campaign of several hours.

## Goal

One tooling for both profiles of ADR-0014, where only the scenario changes:

- generic steps, written once;
- a scenario per profile: which stacks, which steps, which scenes;
- the inputs of the profile set by its scenario, the ones the README lists, plus the outputs of the stacks applied before;
- a report the test results are written from;
- a dry run and unit tests that need no cloud.

Out of scope: changing the stacks, adding test cases (the steps keep their current checks), running campaigns from CI (the GitOps integration point, `v0.7`).

## Design

### 1. Layout

```
tests/campaign/
  run.py                    # command line: run.py <scenario> [--mode interface] [--steps ...] [--dry-run]
  campaign/                 # Python package, standard library only (Python >= 3.11)
    context.py              # configuration, work directory, stack outputs, scenes
    tools.py                # tofu/terraform, kubectl, ssh, openstack: one place to run commands
    probes.py               # HTTPS probes, steady answers, load during a change
    steps/                  # one module per family: foundation, shared_cluster,
                            # published_cluster, exposure, end
    report.py               # the JSON report and its summary
  scenarios/
    private-cloud.toml
    public-cloud.toml
  tests/                    # unit tests (unittest), no cloud
  campaign.local.toml.example
```

`tests/isolation/check.py` stays a tool of its own: the campaign calls it, and a user runs it on any deployment.

### 2. A scenario

A scenario names its profile, the plane modes it runs in, its stacks and its steps:

```toml
profile = "public-cloud"
modes   = ["interface"]
stacks  = ["planes", "receiver", "edge", "web", "isolated"]

[sequences]
foundation = ["prep", "planes", "receiver", "edge", "web", "isolated", "transit", "publish"]
checks     = ["accept", "direct", "hostile"]
end        = ["plans", "teardown", "leftovers"]
full       = ["foundation", "checks", "end"]
```

A step reads the scenario to know what exists: `accept` probes only the domains of the stacks present; the isolation test only gets the kubeconfigs, the authority and the shared cluster that the scenario has, as it does today.

### 3. Inputs

Two sources, in this order:

1. **The profile's inputs**, in the scenario (`[options.inputs.<stack>]`), versioned: the few inputs that differ between the profiles, the ones the README lists. The values of the cloud stay in each stack's `terraform.tfvars`.
2. **The contracts**, computed by the steps from the outputs of the stacks applied before (`plane_attachment`, admission sources, the receiver's URL), written to `mode.auto.tfvars.json` as today.

What only the maintainers have stays in an unversioned `campaign.local.toml`: the `clouds.yaml` entries per stack, the administrator addresses, the test zone, the upgrade versions. No name or address of a test cloud is in the repository.

### 4. Steps

A step is a function of the context. It raises an error to fail; a scene (a change of a stack, then its restore) is a context manager that restores the inputs even when the step fails. Waits and retries go through one helper with a named policy (`ssh`, `octavia`, `entry-point`), declared once. Known failures of the test cloud are repaired outside the repository, through a hook, as today.

### 5. Output

- The commands are printed as they run, so that the recordings (asciinema, one per step) read like a terminal session; `sanitize-cast.py` stays.
- A JSON report per run: the steps, their duration and status, and the measures (isolation rows, HTTPS answers, requests during a publication or an upgrade, leftovers).
- The summary table of the test results is written from the report.

### 6. Without a cloud

- `--dry-run` loads the scenario, expands the sequences, renders the inputs from the scenario and fake outputs, and prints the commands each step would run.
- Unit tests: scenario loading and expansion, input rendering, retry policies, report.
- CI runs both, for both scenarios.

## Dependencies and order

1. The skeleton: `run.py`, the context, the tools, the dry run, the unit tests.
2. The steps, ported one family at a time, each with the same checks as its Bash version. The dry run of a step is compared with the commands its Bash version runs.
3. The private cloud scenario; a full campaign in both plane modes. The Bash tooling is removed only then. *(Done.)*
4. The public cloud scenario, on a public cloud.

## Proposed decisions

1. **Python with its standard library only**: the isolation test is already written in it, a user installs nothing, and the core can be tested without a cloud. Set aside: Bash (error handling, structured data, no unit tests); Go with Terratest (another toolchain for whoever reruns a campaign).
2. **Scenarios in TOML** (`tomllib`, in the standard library).
3. **The scenario sets the inputs of its profile**: the ones the README lists are the ones tested.
4. **One JSON report per run**, the source of the test results.

## Open questions

Settled (2026-11-19): no directory of examples per profile. The profiles differ by a few inputs (the bastion placement, a variable of its own), listed in the README and set by each scenario; the values of the cloud stay in each stack's `terraform.tfvars`.

- How much of the test results is generated: the summary table only, or the detailed sections too.
