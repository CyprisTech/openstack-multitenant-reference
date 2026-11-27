# lz

`lz` deploys a landing zone of the reference from one configuration file, and runs the test campaign of the reference with the same steps ([ADR-0018](../../docs/adr/0018-deployment-tool.md)). Terraform (or OpenTofu) applies each stack; `lz` applies them in order and passes each stack what the others give it: the attachments of the planes, the address of the metrics receiver, the sources of the entry point, the addresses of the consumers of a shared service. It is an orchestrator, not a control plane: it runs when you run it, keeps nothing but the states of the stacks, and every stack can still be applied by hand, as its README says.

Python 3.11 or later, standard library only. Other tools on the machine that runs it: OpenTofu or Terraform, the `openstack` client (with `python-octaviaclient` for the leftover check of `teardown`), and for Kubernetes tenants `kubectl` and `clusterctl`.

## Deploy your landing zone

`lz` runs from the reference's checkout, from any directory: put it on the `PATH` once per shell, from the root of the checkout. The commands below assume it.

```bash
export PATH="$PWD/tools/landing-zone:$PATH"
```

1. `lz init path/to/my-landing-zone` writes your deployment repository: `landing-zone.toml` from the [example](../../examples/deployment/landing-zone.toml), and beside it the `terraform.tfvars.example` of each stack it names, as `<name>.tfvars`.
2. Edit `landing-zone.toml`: the profile and the plane mode, a `clouds.yaml` entry per project, the ranges, the tenants and the shared services, the backend of the states. The comments of the example say what each key is; `lz` checks the file before anything runs, and says which key is wrong.
3. Look at the commands, then deploy:

```bash
lz deploy path/to/landing-zone.toml --dry-run   # the commands, without a cloud
lz deploy path/to/landing-zone.toml
```

**What the configuration declares.** Tenants consume, shared services offer; each is in its own project. Its `type` says what `lz` deploys there:

| Type | What `lz` does |
|---|---|
| `vm` | applies [`stacks/tenants/vm`](../../stacks/tenants/vm) (a tenant) or [`stacks/shared/vm`](../../stacks/shared/vm) (a shared service) in the project, with its own state |
| `kubernetes` | applies [`stacks/tenants/kubernetes`](../../stacks/tenants/kubernetes) (a tenant) or [`stacks/shared/kubernetes`](../../stacks/shared/kubernetes) (a shared service), then creates the cluster from its bootstrap instance |
| `existing` | nothing in the project: attaches it to the planes, for a project you run yourself |

A shared service with `provides` gives values to the tenants (the URL of your receiver, a resolver); `[external]` gives values for services outside the landing zone. Every other input of a stack is in the stack's own file (`inputs`) or in `values`, as in the stack's README; what `lz` writes wins over both.

**What `deploy` runs**, in this order: the planes; the shared egress, if declared; the entry point; each tenant; each shared service (after the tenants: it admits its consumers by their addresses); the tenants of the shared egress, declared on it; the planes again, so that the routes of the transit routers follow the attachments ([ADR-0013](../../docs/adr/0013-plane-routes-on-a-transit-router.md)); the publication of the domains; each Kubernetes cluster. Each apply must end with an empty plan; `lz` stops at the first failure, and a run started again goes on from the states.

**States and credentials.** With `[state]`, each stack's state is a key of your backend (`{stack}` in `key`); without it, a local state beside each stack, which is then yours to keep safe. The kubeconfig of each cluster is written to `tools/landing-zone/work/deploy-<mode>/<name>.kubeconfig`: keep it as you keep the states, it is the administrator's access to the cluster. Settings of the machine that runs `lz` (hooks, see below) go in `lz.local.toml` beside the configuration, not versioned.

## Commands

Each command takes the configuration file of a deployment, or a scenario of the reference by name (`private-cloud`, `public-cloud`) for its test deployment. `--dry-run` prints the commands without running them.

| Command | What it does |
|---|---|
| `init` | a deployment repository: `landing-zone.toml` and an inputs file per stack, from the example |
| `deploy` | your landing zone, from its configuration file |
| `plan` | what an apply would change in each deployed stack, kept in `<work>/plans`; nothing is changed. Exit code 2 when something would change |
| `status` | what is deployed: each stack and the number of its resources, the kubeconfig of each cluster |
| `update-clusters` | each deployed cluster takes the manifests of its stack, as after an apply ([lifecycle](../../docs/guides/kubernetes-lifecycle.md)) |
| `upgrade` | this release applied over the deployed one, stack by stack ([upgrade guide](../../docs/guides/upgrade.md)) |
| `teardown` | everything destroyed, in waves, then a check that nothing is left ([teardown guide](../../docs/guides/teardown.md)) |
| `try` | the reference with its test fixtures (a receiver, an ACME authority, a resolver, an internal service), on test projects |
| `apply` | the steps or sequences given, of a scenario |
| `campaign` | the test campaign of the reference: `try`, its checks, the teardown (below) |

Before the first step, `lz` checks that every `clouds.yaml` entry it will use authenticates. It also refuses to start when the projects hold objects while no state of the deployment does, since `teardown` destroys what the states hold and a `clouds.yaml` entry pointing at the wrong project must not lead it there; `--allow-existing` starts anyway, `--no-preflight` skips the checks.

## Try the reference

`lz try private-cloud` deploys the reference's own scenario with its test fixtures, on projects made for it: the [test procedure](../../docs/reference/test-procedure.md) says which projects and entries. Its tenants and shared services are declared in [`scenarios/private-cloud.toml`](scenarios/private-cloud.toml) in the same format as a deployment, and deployed by the same steps.

## Test campaign

`lz campaign` runs the campaign described in the [test procedure](../../docs/reference/test-procedure.md), from empty projects to an empty teardown. It deploys the scenario of a profile ([ADR-0014](../../docs/adr/0014-profiles.md)) as `deploy` does, requires an empty plan after each apply, runs the [isolation test](../../tests/isolation/README.md) and the HTTPS checks, the scenes (direct exposure, a consumer, the hostile route), the credential rotation, the Kubernetes upgrade and, with `--from`, the upgrade from the previous release; then it tears everything down. To use the reference, you do not need it: it is how the maintainers run the guides end to end before each release.

**What each step runs.** A step names the sections of the documentation it runs, `@step(name, guide=...)`: its section of the test procedure and the guide or README an adopter follows for the same thing. The report gives them for each step that passed (`guide=` in `report.json`). A unit test checks that each named file and heading exists, and that every step names its sections or is listed in `UNDOCUMENTED` with the reason; a change to a procedure updates the step that names it.

```bash
cp tools/landing-zone/campaign.local.toml.example tools/landing-zone/campaign.local.toml   # adapt
# and a terraform.tfvars for each stack and fixture, from its terraform.tfvars.example
lz campaign private-cloud --mode gateway full
lz apply private-cloud --mode interface planes tenant-web   # or a few steps
lz campaign public-cloud full
lz campaign private-cloud --dry-run full                   # the commands, without a cloud
lz campaign private-cloud --mode interface --from v0.5.1   # the upgrade from a release
PYTHONPATH=tools/landing-zone python3 -m unittest discover -s tests/landing_zone -t tests/landing_zone
```

The campaign also needs `curl`, `asciinema` with `--record`, and PyYAML (installed with the `openstack` client), with which step `prep` reads `clouds.yaml`.

`campaign.local.toml` (git-ignored) holds what is specific to the maintainers' cloud: the `clouds.yaml` entry of each stack, the planes of each mode, the SSH access, the test zone, the credentials of the clusters, the hooks. Nothing else changes from a cloud to another: the tenants, the attachments of the planes and their ranges are in the scenario. The preflight also checks, when the rotation runs, that the next credential of the shared cluster exists and is not the current one.

With a `notify_hook`, the operator is told when the campaign starts and ends, when each step starts and ends (with its duration and measures), when an action is needed (marked ⚠️), and why the campaign stopped; `notify_steps = false` keeps the actions and the stops only.

The campaign stops at the first failure: a command that fails, a request that fails, a plan that is not empty, an instance that does not come up. The teardown runs in three waves, the stacks of a wave destroyed in parallel: the clusters (deleted by Cluster API, then their stack) and the tenants; the shared services and the fixtures; the planes. A failure lets the other stacks of its wave finish, then stops before the next wave, which depends on it; the leftover check reports what remains. The two Kubernetes clusters are deployed one after the other, so that it fits a small test cloud ([sizing](#sizing)).

Outputs, under `tools/landing-zone/work/<scenario>-<mode>` (git-ignored): `report.json` (each step, its status, duration and measures — HTTPS counts, time to a steady answer, loads — and the duration of each apply and destroy), `isolation-*.txt`, `https.txt`, `timings.txt`, `logs/` (full output of each apply and of the cluster scripts), the kubeconfigs, the regenerated [Kubernetes tour](../../docs/guides/kubernetes-tour.md).

## Upgrade from the previous release

`--from <tag>` tests the upgrade of a deployment ([ADR-0017](../../docs/adr/0017-upgrades-between-releases.md)). The release campaign runs it in one of its two modes; the other mode deploys from empty.

1. A git worktree at the tag, `work/<scenario>-<mode>-tree`, deploys the previous release with its own campaign tool: the steps of `options.from.previous` of the scenario (the foundation and the shared cluster, without acceptance). Done once: a run started again skips it.
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
| `lz` | Command line: the commands, the scenario or the configuration, the mode, the steps; recording; the report |
| `scenarios/` | `private-cloud.toml`, `public-cloud.toml`: the stacks, the sequences and the settings of the steps of each profile |
| `landing_zone/` | Scenario loading, the context of a step (stacks, inputs, scenes, apply), the tools (`tofu`, `openstack`, a runner with a dry run), retries, the report |
| `landing_zone/deployment.py` | The configuration of a deployment: its checks, its scenario, the steps of its tenants and shared services (`tenant-<name>`, `service-<name>`, `cluster-<name>`) |
| `landing_zone/commands.py` | `plan`, `status`, `update-clusters` |
| `landing_zone/kube.py`, `landing_zone/checks.py` | The clusters and their bootstrap instance; the isolation test and the HTTPS checks |
| `landing_zone/previous.py` | The upgrade from the previous release: its worktree, its deployment, what each plan replaces and destroys |
| `landing_zone/steps/` | The steps of the reference's fixtures and checks, one module per family: `foundation`, `shared` (the shared cluster's checks), `published` (the published cluster's checks and the scenes), `end`, `upgrade` (step `migrate`) |
| `../../tests/landing_zone/` | Unit tests, no cloud |

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
