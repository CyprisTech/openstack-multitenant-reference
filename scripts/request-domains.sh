#!/usr/bin/env bash
# Write the change a tenant asks for: the domains of a tenant stack (its published_domains output),
# merged into the domains of the public entry point, stacks/shared/entry-point/domains.auto.tfvars.json.
#
# The file is a reviewed input of the entry point (ADR-0016, D5), kept in your deployment
# repository: commit it and open a merge request; once it is reviewed and merged,
# scripts/publish-domains.sh applies it. A domain already in the file takes the tenant's new
# service address. To withdraw a domain, remove its entry from the file.
#
#     scripts/request-domains.sh stacks/tenants/vm [--tool tofu|terraform]
#
# Reads the state of the given tenant stack only. Needs jq.
set -euo pipefail

tool=tofu
stack=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) tool="$2"; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) stack="$1"; shift ;;
  esac
done
[[ -n "${stack}" ]] || { echo "usage: $0 <tenant stack> [--tool tofu|terraform]" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
domains_file="${root}/stacks/shared/entry-point/domains.auto.tfvars.json"

if ! out=$("${tool}" -chdir="${stack}" output -json published_domains 2>/dev/null); then
  echo "$(basename "${stack}") has no published_domains output: apply it first" >&2
  exit 1
fi
if [[ "$(jq 'length' <<<"${out}")" == 0 ]]; then
  echo "$(basename "${stack}") publishes no domain through the entry point: nothing to request"
  exit 0
fi

current='{"domains": {}}'
[[ -f "${domains_file}" ]] && current=$(cat "${domains_file}")
new=$(jq --argjson asked "${out}" '.domains += $asked' <<<"${current}")
if diff -q <(jq -S . <<<"${current}") <(jq -S . <<<"${new}") >/dev/null; then
  echo "domains of $(basename "${stack}") already in the file: nothing to request"
  exit 0
fi
echo "${new}" | jq . > "${domains_file}"
for domain in $(jq -r 'keys[]' <<<"${out}"); do
  before=$(jq -c --arg d "${domain}" '.domains[$d] // empty' <<<"${current}")
  echo "${domain}: $([[ -z "${before}" ]] && echo added || echo updated) -> $(jq -c --arg d "${domain}" '.[$d].backends' <<<"${out}")"
done
echo "written to ${domains_file#"${root}"/}: commit it and open a merge request"
