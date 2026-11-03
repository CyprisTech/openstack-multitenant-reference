#!/usr/bin/env bash
# Publish the domains of the tenants on the public entry point (stack shared/entry-point).
#
# Collects the `published_domains` output of every applied stack under stacks/tenants, writes them
# to stacks/shared/entry-point/domains.auto.tfvars.json and, when they changed, applies the entry
# point. The routes reach the Traefik instances through their metadata, updated in place: no
# instance is replaced, and they take effect within seconds (ADR-0006, D3).
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

# 1. Domains of the applied tenant stacks. A stack that does not publish domains, or is not
#    deployed, is skipped; a deployed stack whose state lacks the output stops the script (its
#    configuration is newer than its state: apply it first).
domains='{}'
for stack in "${root}"/stacks/tenants/*/; do
  grep -qs 'output "published_domains"' "${stack}"*.tf || continue
  [[ -d "${stack}/.terraform" ]] || continue
  [[ -n "$("${tool}" -chdir="${stack}" state list 2>/dev/null | head -1)" ]] || continue
  if ! out=$("${tool}" -chdir="${stack}" output -json published_domains 2>/dev/null); then
    echo "$(basename "${stack}") is deployed but its state has no published_domains output: apply it first" >&2
    exit 1
  fi
  if [[ -n "${out}" ]]; then
    echo "domains from $(basename "${stack}"): $(jq -r 'keys | join(", ")' <<<"${out}")"
    domains=$(jq -s '.[0] * .[1]' <(echo "${domains}") <(echo "${out}"))
  fi
done
new=$(jq '{domains: .}' <<<"${domains}")

# An empty publication would withdraw every domain from the entry point.
if [[ "${allow_empty}" != true && "$(jq 'length' <<<"${domains}")" == 0 && -f "${domains_file}" \
      && "$(jq '.domains | length' "${domains_file}")" != 0 ]]; then
  echo "no domain found, while domains are published: refusing to remove them all (--allow-empty to force)" >&2
  exit 1
fi

if [[ -f "${domains_file}" ]] && diff -q <(jq -S . "${domains_file}") <(jq -S . <<<"${new}") >/dev/null; then
  echo "domains unchanged: nothing to do"
  exit 0
fi
echo "${new}" > "${domains_file}"

# 2. Apply the entry point: its instances' metadata is updated in place.
"${tool}" -chdir="${edge}" apply -auto-approve -input=false
echo "domains published: $(jq -r '.domains | keys | join(", ")' <<<"${new}")"
