# Rebuild the architecture

The architecture is code: after the loss of a project, a stack, a region or the whole cloud, it is rebuilt from the repository and the inputs, in a fixed order. What is not code is the tenants' data, and the states. This guide covers what the reference owns ([ADR-0012](../adr/0012-resilience-scope.md)); restoring the tenants' data is theirs, through the backup integration point.

## What you need, kept outside the cloud

| What | Why | How to keep it |
|---|---|---|
| The repository, at the release you run | the code of every stack | your git server, and a mirror |
| The inputs of each stack (`terraform.tfvars`, `clouds.yaml` entries) | the values that make it your deployment | a secret store or an encrypted repository, never next to the states only |
| The states | they map the code to the objects of the cloud, and contain secrets (credentials, keys, the passwords a stack generates) | a backend with versioning and encryption, itself backed up outside the cloud it describes |
| The node image of the Kubernetes clusters | rebuilding it takes time | its build files are in the repository (`images/kubernetes-node`); keep the image in another region or rebuild it |

A state lost for good is not a disaster: the stack is applied again from empty projects, or takes back the objects that survived with `import` blocks. A state given to the wrong person is one: it holds credentials.

## Order

The order of creation, as in the [test procedure](../reference/test-procedure.md): each stack needs the outputs of the previous ones. A shared service is created before its consumers, closed, and opened to them once they exist, as in [open a service](open-a-service.md).

| Step | Stacks | Needs |
|---|---|---|
| 0 | Projects, quotas, roles, credentials, external networks | the cloud foundation (level 1), not this repository |
| 1 | `shared/planes` | the external networks (operator planes) or the hub project |
| 2 | shared services: receiver, ACME authority, internal services (closed) | the planes |
| 3 | `shared/entry-point` | the planes, the receiver |
| 4 | tenants: `vm` (each of its tenants, with its own state), `kubernetes` | the planes, the receiver, the entry point's sources, the certificates |
| 5 | Kubernetes clusters (`create-cluster.sh`), shared cluster | their stacks |
| 6 | open the internal services to their consumers (`allowed_sources`, `consumers`), in place | the tenants' sources |
| 7 | `shared/planes` again (hub planes) | the tenants' attachments, for the transit routes |
| 8 | domain publication (`scripts/publish-domains.sh`), from the domains file of your deployment repository | the tenants' service addresses, unchanged when the stacks keep their addresses |
| 9 | the [isolation test](check-isolation.md) | everything above |

Rebuild only what was lost, from the first lost step: the stacks after it plan no change if their inputs did not change, or update in place when an address did (a new service address, new sources).

| Lost | Rebuild |
|---|---|
| a tenant | its stack (step 4), its cluster if any (step 5), then steps 6 to 9: its sources may have changed (a new router address on a plane with address translation) |
| the entry point | step 3, then the tenants' `edge_sources` (step 4, in place), steps 8 and 9 |
| the receiver or the ACME authority | step 2, then the stacks that use it (in place), step 9 |
| an internal service | step 2, opened with its current consumers (step 6), then step 9 |
| the planes | everything: every attachment depends on them |
| a region | every step, in the region's projects; the public names fail over by DNS to another region if you run one |

## Proven by the campaign

Every test campaign builds the whole architecture from empty projects in this order, checks an empty plan after each apply, runs the isolation test, then tears everything down ([test results](../concepts/test-results.md)). A rebuild is that campaign without the teardown, with your inputs and your states.

What the campaign does not prove: the restore of the tenants' data, and a rebuild in another region or on another cloud than the tested one.
