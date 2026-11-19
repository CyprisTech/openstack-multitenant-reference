# Test campaign

`run.sh` runs the campaign described in the [test procedure](../../docs/reference/test-procedure.md), from empty projects to an empty teardown: it applies each stack, requires an empty plan, runs the [isolation test](../isolation/README.md) and the HTTPS checks, and keeps the outputs.

## Usage

```bash
cp tests/campaign/campaign.env.example tests/campaign/campaign.env   # adapt
# and a terraform.tfvars for each stack and fixture, from its terraform.tfvars.example
tests/campaign/run.sh gateway full
tests/campaign/run.sh interface planes edge    # or a few steps
```

Tools on the machine that runs it: OpenTofu or Terraform, the `openstack` client with its Octavia plugin (`python-octaviaclient`, for the load balancers of the leftover check), `kubectl`, `clusterctl`, `jq`, `curl`, `python3`, and `asciinema` with `RECORD=1`.

The campaign stops at the first failure: a command that fails, a request that fails, a plan that is not empty, an instance that does not come up. The teardown goes on after a failure, to remove as much as it can, and reports it. The two Kubernetes clusters are deployed one after the other, so that it fits a small test cloud ([sizing](#sizing)).

Outputs, under `tests/campaign/work/<mode>` (git-ignored): `isolation-*.txt`, `https.txt`, `plans.txt`, `timings.txt`, the regenerated [Kubernetes tour](../../docs/guides/kubernetes-tour.md).

## Sizing

The campaign tests behaviour, not capacity: each instance gets the smallest size that runs its role. The maintainers use, in the stacks' `terraform.tfvars`:

| Stack | Size | Why it is enough |
|---|---|---|
| shared cluster | 3 control plane nodes and 2 workers, 2 vCPU and 4 GB each | the high availability of the control plane, the upgrade and the credential rotation are tested on this cluster |
| published cluster | 1 control plane node and 2 workers (`control_plane_count = 1`) | its tests (isolation, publication, direct exposure, consumers) do not depend on the control plane's availability; the two workers carry the two Traefik replicas, spread on two nodes |
| bootstrap instances | 2 vCPU and 4 GB | kind runs there |
| entry point, `vm`, `isolated`, internal service, ACME authority | 1 vCPU and 1 GB | nginx, Traefik, Knot, step-ca and the metrics agent |
| receiver | 2 vCPU and 2 GB | Prometheus |

A smaller cloud can also run the shared cluster with one control plane node: the upgrade is then tested without a highly available control plane.

## Python tooling, by profile (in progress)

The campaign is being moved to Python, with a scenario per profile ([ADR-0014](../../docs/adr/0014-profiles.md), [spec](../../docs/specs/campaign-tooling.md)). `run.sh` stays the tool that runs a campaign until every step is ported and a full campaign of the private cloud profile has passed with `run.py`.

```bash
cp tests/campaign/campaign.local.toml.example tests/campaign/campaign.local.toml   # adapt
tests/campaign/run.py private-cloud --mode gateway full
tests/campaign/run.py public-cloud plans leftovers      # a few steps
tests/campaign/run.py private-cloud --dry-run full      # the commands, without a cloud
python3 -m unittest discover -s tests/campaign/tests -t tests/campaign
```

| Path | Content |
|---|---|
| `run.py` | Command line: the scenario, the mode, the steps; the report (`work/<scenario>-<mode>/report.json`) |
| `campaign/` | The package: scenario loading, context (stacks, inputs, scenes), tools (`tofu`, `openstack`), retries, report |
| `campaign/steps/` | The steps, one module per family; ported so far: the foundation (`prep` to `publish`), `plans`, `leftovers` |
| `scenarios/` | `private-cloud.toml`, `public-cloud.toml`: the stacks and the sequences of each profile |
| `tests/` | Unit tests, no cloud |

A step not ported yet is listed as such and skipped. Python 3.11 or later, standard library only; step `prep` reads `clouds.yaml` with PyYAML, installed with the `openstack` client. The settings of `campaign.env` are in `campaign.local.toml` (see the example); the attachments of the planes and their ranges are in the scenario. Recording (`RECORD=1`) is not ported yet.

## How it is organised

| File | Content |
|---|---|
| `run.sh` | Arguments, configuration, the sequences, recording of each step |
| `lib/helpers.sh` | Stack inputs and outputs, apply and destroy, access to the instances, clusters, checks |
| `steps/1-foundation.sh` | Sequence `foundation`: planes, fixtures, entry point, `vm` and `isolated` tenants, publication |
| `steps/2-shared-cluster.sh` | Sequence `shared`: the shared cluster, its acceptance, a consumer added, removal |
| `steps/3-published-cluster.sh` | Sequence `published`: the published cluster, acceptance, hostile route |
| `steps/4-end.sh` | Sequence `end`: plans still empty, teardown, nothing left in the projects |

A step that changes a stack and restores it (direct exposure, a consumer, the hostile route) keeps the stack's inputs first and restores them at the end; run again after a failure, it starts from the inputs it kept. An instance whose cloud-init ends in error stops the campaign, it is not retried.

A step is a function `step_<name>`; `full` runs the four sequences in order. The inputs a stack receives from the others are written by `set_inputs` to its `mode.auto.tfvars.json`.

## Recordings

With `RECORD=1`, each step is recorded with [asciinema](https://asciinema.org) in `casts/`, with the full output of the tools. Recordings show real addresses: before publishing one, run

```bash
tests/campaign/sanitize-cast.py input.cast output.cast --replace internal.name=example.org --forbid internal
```

It replaces the addresses outside the cluster networks with documentation addresses and refuses to write the file if an address or a forbidden word remains. Names it cannot know about are yours to list; watch the result before publishing it.
