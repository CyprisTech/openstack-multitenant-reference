#!/usr/bin/env bash
# Publish the domains on the public entry point (stack shared/entry-point).
#
# The domains are a reviewed input of the entry point (ADR-0016, D5): the file
# stacks/shared/entry-point/domains.auto.tfvars.json, kept in your deployment repository and changed
# by a reviewed merge request (scripts/request-domains.sh writes the change a tenant asks for).
# The script plans the entry point and, when the plan is not empty, applies that plan. The routes
# reach the Traefik instances through their metadata, updated in place: no instance is replaced,
# and they take effect within seconds (ADR-0006, D3). It reads no state of the tenants.
#
#     OS_CLOUD=<entry of the entry point's project> scripts/publish-domains.sh [--tool tofu|terraform] [--allow-empty]
#
# Needs jq.
set -euo pipefail

tool=tofu
allow_empty=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) tool="$2"; shift 2 ;;
    --allow-empty) allow_empty=true; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
: "${OS_CLOUD:?set OS_CLOUD to the clouds.yaml entry of the entry point}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
edge="${root}/stacks/shared/entry-point"
domains_file="${edge}/domains.auto.tfvars.json"
plan=publish-domains.tfplan

if [[ ! -f "${domains_file}" ]]; then
  echo "no ${domains_file#"${root}"/}: write it with scripts/request-domains.sh, or by hand" >&2
  exit 1
fi
if ! jq -e '.domains | type == "object"' "${domains_file}" >/dev/null 2>&1; then
  echo "${domains_file#"${root}"/} must hold {\"domains\": {...}}" >&2
  exit 1
fi
wanted=$(jq -c '.domains | keys' "${domains_file}")
published=$("${tool}" -chdir="${edge}" output -json domains 2>/dev/null || echo '[]')

# An empty file would withdraw every domain from the entry point.
if [[ "${allow_empty}" != true && "$(jq 'length' <<<"${wanted}")" == 0 && "$(jq 'length' <<<"${published}")" != 0 ]]; then
  echo "the file lists no domain, while domains are published: refusing to remove them all (--allow-empty to force)" >&2
  exit 1
fi

# Exit status of the plan: 0 nothing to change, 2 changes, anything else an error.
status=0
"${tool}" -chdir="${edge}" plan -input=false -detailed-exitcode -out="${plan}" >/dev/null || status=$?
if [[ "${status}" != 2 ]]; then
  rm -f "${edge}/${plan}"
  if [[ "${status}" == 0 ]]; then
    echo "domains unchanged: nothing to do"
    exit 0
  fi
  echo "plan of the entry point failed: run ${tool} -chdir=stacks/shared/entry-point plan" >&2
  exit 1
fi
# What the plan changes in the routes: the route-<domain> metadata items of the instances
# (informative only: the apply goes on if the plan cannot be read).
changes=$("${tool}" -chdir="${edge}" show -json "${plan}" | jq -c '
  [.resource_changes[] | select(.change.actions | index("update"))
   | (.change.before.metadata // {}) as $b | (.change.after.metadata // {}) as $a
   | ($b + $a | keys[] | select(startswith("route-"))) as $k
   | select($b[$k] != $a[$k])
   | {d: ($k | ltrimstr("route-")), s: (if $b[$k] == null then "added" elif $a[$k] == null then "withdrawn" else "changed" end)}]
  | unique | group_by(.s) | map({key: .[0].s, value: (map(.d) | join(", "))}) | from_entries') || changes='{}'
for kind in added changed withdrawn; do
  list=$(jq -r --arg k "${kind}" '.[$k] // empty' <<<"${changes}")
  [[ -z "${list}" ]] || echo "domains ${kind}: ${list}"
done

"${tool}" -chdir="${edge}" apply -input=false "${plan}"
rm -f "${edge}/${plan}"
echo "domains published: $(jq -r 'if length == 0 then "none" else join(", ") end' <<<"${wanted}")"
