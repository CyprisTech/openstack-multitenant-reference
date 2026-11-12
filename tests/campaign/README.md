# Test campaign

`run.sh` runs the campaign described in the [test procedure](../../docs/reference/test-procedure.md), from empty projects to an empty teardown: it applies each stack, requires an empty plan, runs the [isolation test](../isolation/README.md) and the HTTPS checks, and keeps the outputs.

## Usage

```bash
cp tests/campaign/campaign.env.example tests/campaign/campaign.env   # adapt
# and a terraform.tfvars for each stack and fixture, from its terraform.tfvars.example
tests/campaign/run.sh gateway full
tests/campaign/run.sh interface planes edge    # or a few steps
```

The campaign stops at the first failure: a command that fails, a request that fails, a plan that is not empty, an instance that does not come up. The teardown goes on after a failure, to remove as much as it can, and reports it. The two Kubernetes clusters are deployed one after the other, so that it fits a small test cloud; on a smaller one, set `control_plane_count = 1` in their `terraform.tfvars`.

Outputs, under `tests/campaign/work/<mode>` (git-ignored): `isolation-*.txt`, `https.txt`, `plans.txt`, `timings.txt`, the regenerated [Kubernetes tour](../../docs/guides/kubernetes-tour.md).

## How it is organised

| File | Content |
|---|---|
| `run.sh` | Arguments, configuration, the sequences, recording of each step |
| `lib/helpers.sh` | Stack inputs and outputs, apply and destroy, access to the instances, clusters, checks |
| `steps/1-foundation.sh` | Sequence `foundation`: planes, fixtures, entry point, `vm` and `isolated` tenants, publication |
| `steps/2-shared-cluster.sh` | Sequence `shared`: the shared cluster, its acceptance, a consumer added, removal |
| `steps/3-published-cluster.sh` | Sequence `published`: the published cluster, acceptance, hostile route |
| `steps/4-end.sh` | Sequence `end`: plans still empty, teardown |

A step is a function `step_<name>`; `full` runs the four sequences in order. The inputs a stack receives from the others are written by `set_inputs` to its `mode.auto.tfvars.json`.

## Recordings

With `RECORD=1`, each step is recorded with [asciinema](https://asciinema.org) in `casts/`, with the full output of the tools. Recordings show real addresses: before publishing one, run

```bash
tests/campaign/sanitize-cast.py input.cast output.cast --replace internal.name=example.org --forbid internal
```

It replaces the addresses outside the cluster networks with documentation addresses and refuses to write the file if an address or a forbidden word remains. Names it cannot know about are yours to list; watch the result before publishing it.
