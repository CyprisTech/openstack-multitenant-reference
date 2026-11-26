# Test campaign

`run.py` runs the campaign described in the [test procedure](../../docs/reference/test-procedure.md), from empty projects to an empty teardown. It applies each stack, requires an empty plan, runs the [isolation test](../../tests/isolation/README.md) and the HTTPS checks, and keeps the outputs. A scenario per profile ([ADR-0014](../../docs/adr/0014-profiles.md)) names the stacks and the steps; the steps themselves are shared.

**What to read.** To use the reference, you do not need this directory: the [isolation test](../../tests/isolation/README.md) and the [guides](../../docs/guides) are what you run on your deployment. The campaign is the maintainers' tool: it runs those guides, end to end and upgrades included, before each release.

**Why its own tool.** Terratest and `tofu test` with a real provider test one configuration at a time. A campaign spans several projects and stacks, feeding each stack the outputs of the others, two Kubernetes clusters created and upgraded by Cluster API, loads that must not fail during an apply, and the upgrade from the previous release; and it must resume after an interruption and leave the projects empty. Python's standard library and the `tofu` and `openstack` command lines are enough for that, without a framework to learn.

**What each step runs.** A step names the sections of the documentation it runs, `@step(name, guide=...)`: its section of the [test procedure](../../docs/reference/test-procedure.md) and the guide or README an adopter follows for the same thing. The report gives them for each step that passed (`guide=` in `report.json`). A unit test checks that each named file and heading exists, and that every step names its sections or is listed in `UNDOCUMENTED` with the reason; a change to a procedure updates the step that names it.

## Usage

```bash
cp tools/landing-zone/campaign.local.toml.example tools/landing-zone/campaign.local.toml   # adapt
# and a terraform.tfvars for each stack and fixture, from its terraform.tfvars.example
tools/landing-zone/lz private-cloud --mode gateway full
tools/landing-zone/lz private-cloud --mode interface planes edge   # or a few steps
tools/landing-zone/lz public-cloud full
tools/landing-zone/lz private-cloud --dry-run full                 # the commands, without a cloud
tools/landing-zone/lz private-cloud --mode interface --from v0.5.1 # the upgrade from a release
PYTHONPATH=tools/landing-zone python3 -m unittest discover -s tests/landing_zone -t tests/landing_zone
```

Python 3.11 or later, standard library only; step `prep` reads `clouds.yaml` with PyYAML, installed with the `openstack` client. Other tools on the machine that runs it: OpenTofu or Terraform, the `openstack` client with its Octavia plugin (`python-octaviaclient`, for the load balancers of the leftover check), `kubectl`, `clusterctl`, `curl`, and `asciinema` with `--record`.

`campaign.local.toml` (git-ignored) holds what is specific to the maintainers' cloud: the `clouds.yaml` entry of each stack, the planes of each mode, the SSH access, the test zone, the credentials of the clusters, the hooks. Nothing else changes from a cloud to another: the attachments of the planes and their ranges are in the scenario.

Before the first step, the campaign checks that every `clouds.yaml` entry it will use authenticates, those of the clusters included, and, when the rotation runs, that the next credential of the shared cluster exists and is not the current one; `--no-preflight` skips it. A credential revoked or misspelled stops the run before anything is created. So do projects that hold objects while no state of the campaign does: the campaign creates then destroys everything, and a `clouds.yaml` entry pointing at the wrong project must not lead it to destroy what it finds there. A run started again finds its own states and goes on; `--allow-existing` starts anyway.

With a `notify_hook`, the operator is told when the campaign starts and ends, when each step starts and ends (with its duration and measures), when an action is needed (marked ⚠️), and why the campaign stopped; `notify_steps = false` keeps the actions and the stops only.

The campaign stops at the first failure: a command that fails, a request that fails, a plan that is not empty, an instance that does not come up. The teardown runs in three waves, the stacks of a wave destroyed in parallel: the clusters (deleted by Cluster API, then their stack) and the tenants; the shared services and the fixtures; the planes. A failure lets the other stacks of its wave finish, then stops before the next wave, which depends on it; the leftover check reports what remains. The two Kubernetes clusters are deployed one after the other, so that it fits a small test cloud ([sizing](#sizing)).

Outputs, under `tools/landing-zone/work/<scenario>-<mode>` (git-ignored): `report.json` (each step, its status, duration and measures — HTTPS counts, time to a steady answer, loads — and the duration of each apply and destroy), `isolation-*.txt`, `https.txt`, `timings.txt`, `logs/` (full output of each apply and of the cluster scripts), the regenerated [Kubernetes tour](../../docs/guides/kubernetes-tour.md).

## Upgrade from the previous release

`--from <tag>` tests the upgrade of a deployment ([spec](../../docs/specs/upgrades.md), [ADR-0017](../../docs/adr/0017-upgrades-between-releases.md)). The release campaign runs it in one of its two modes; the other mode deploys from empty.

1. A git worktree at the tag, `work/<scenario>-<mode>-tree`, deploys the previous release with its own `run.py`: the steps of `options.from.previous` of the scenario (the foundation and the shared cluster, without acceptance). Done once: a run started again skips it.
2. The worktree checks out the commit under test: the states and the inputs, outside git, stay where they are, as for a user who pulls a new release. The commit must be committed: the worktree only sees commits.
3. Step `migrate` applies the new release over them, with the steps of `options.from.apply`: each deployed stack is planned (the plan kept in `plans/`), then applied; the stacks the release adds are created; the shared cluster is updated with `update-cluster.sh` from the campaign host. Requests run during all the applies: a published domain through the entry point, and the shared cluster's internal service from a tenant instance.
4. The rest of the scenario, unchanged (sequence `from-previous`): acceptance, rotation, Kubernetes upgrade, the published cluster, the end.

`migration.json` lists, per stack, the resources the upgrade replaced and destroyed and the requests that failed during its apply: the draft of the migration notes of the release. The previous release's own report is kept as `report-previous.json`. After the run, remove the worktree with `git worktree remove`.

## Sizing

The campaign tests behaviour, not capacity: each instance gets the smallest size that runs its role. The maintainers use, in the stacks' `terraform.tfvars`:

| Stack | Size | Why it is enough |
|---|---|---|
| shared cluster | 3 control plane nodes and 2 workers, 2 vCPU and 4 GB each, on 20 GiB volumes (`control_plane_root_volume_size`, `worker_root_volume_size`) | the high availability of the control plane, the upgrade and the credential rotation are tested on this cluster |
| published cluster | 1 control plane node and 2 workers (`control_plane_count = 1`) | its tests (isolation, publication, direct exposure, consumers) do not depend on the control plane's availability; the two workers carry the two Traefik replicas, spread on two nodes |
| bootstrap instances | 2 vCPU and 4 GB, on a 20 GiB volume (`boot_volume_size = 20`) | kind runs there |
| entry point, `vm` (web and private tenants), internal service, ACME authority | 1 vCPU and 1 GB | nginx, Traefik, Knot, step-ca and the metrics agent |
| receiver | 2 vCPU and 2 GB | Prometheus |

A smaller cloud can also run the shared cluster with one control plane node: the upgrade is then tested without a highly available control plane.

The Kubernetes nodes and the bootstrap instances boot from Cinder volumes, as the stacks do by default: the local disks of the compute nodes are then not a limit, and a rollout needs one volume more per machine replaced. The projects of the clusters need a volume quota of about 15 (the nodes, one more during a rollout, the bootstrap instance, the volumes of the checks).

## How it is organised

| Path | Content |
|---|---|
| `run.py` | Command line: the scenario, the mode, the steps; recording; the report |
| `scenarios/` | `private-cloud.toml`, `public-cloud.toml`: the stacks, the sequences and the settings of the steps of each profile |
| `campaign/` | Scenario loading, the context of a step (stacks, inputs, scenes, apply), the tools (`tofu`, `openstack`, a runner with a dry run), retries, the report |
| `campaign/kube.py`, `campaign/checks.py` | The clusters and their bootstrap instance; the isolation test and the HTTPS checks |
| `campaign/previous.py` | The upgrade from the previous release: its worktree, its deployment, what each plan replaces and destroys |
| `campaign/steps/` | The steps, one module per family: `foundation`, `shared` (the shared cluster), `published` (the published cluster and the scenes), `end`, `upgrade` (step `migrate`) |
| `tests/` | Unit tests, no cloud |

A step that changes a stack and restores it (direct exposure, a consumer, the hostile route) is a scene: it keeps the stack's inputs first and restores them even when it fails; run again after a failure, it starts from the inputs it kept. An instance whose cloud-init ends in error stops the campaign, it is not retried.

The inputs a stack receives from the others are written to its `mode.auto.tfvars.json`, which tofu loads by itself: a plain apply of the stack, or `scripts/publish-domains.sh`, uses them too.

Two tenants of one stack, such as the web and private tenants of `stacks/tenants/vm`, share its directory: each has its own state (`<name>.tfstate`, the local backend of a git-ignored `backend_override.tf`) and its own data directory, declared in the scenario as `{ path, state }`. Its inputs go to `mode.<name>.tfvars.json`, given with `-var-file` (an auto file would be read by every tenant), and its commands run with `TF_DATA_DIR`, as the printed commands show; the isolation test reads each tenant's outputs from a file the campaign writes:

```console
$ TF_DATA_DIR=.terraform/tenant-private tofu -chdir=stacks/tenants/vm apply -auto-approve -input=false -no-color -var-file=mode.private.tfvars.json
```

`notify_hook` (optional) tells the operator, given a message: when the campaign waits for someone (the revocation of the old credential, in step `rotate`) and when it stops. `repair_hook` (optional) may clean a known failure of your test cloud after a failed apply: given the stack path, it prints extra apply arguments.

## Recordings

With `--record`, each step is recorded with [asciinema](https://asciinema.org) in `casts/`, with the full output of the tools: each apply and destroy as it runs, and the output of every command the step shows. The same output is printed by the campaign itself, step after step, so that its log is readable without the recordings. Recordings show real addresses: before publishing one, run

```bash
tools/landing-zone/sanitize-cast.py input.cast output.cast --replace internal.name=example.org --forbid internal
```

It replaces the addresses outside the cluster networks with documentation addresses and refuses to write the file if an address or a forbidden word remains. Names it cannot know about are yours to list; watch the result before publishing it.
