#!/usr/bin/env bash
# Publish the routes of the tenants on the public entry point (stack 20).
#
# Collects the `routes` output of every applied stack under stacks/30-tenants (or its routes.json
# file, for routes known only after deployment, such as a Kubernetes ingress), writes them to
# stacks/20-public-edge/routes.auto.tfvars.json and, when they changed, replaces the entry point
# instances one at a time: routes are written by cloud-init, and the load balancer keeps a healthy
# member while the other instance is replaced.
#
#     OS_CLOUD=<entry of stack 20> scripts/publish-routes.sh [--tool tofu|terraform]
#
# Needs jq and the openstack client (to wait for the load balancer members).
set -euo pipefail

tool=tofu
[[ "${1:-}" == "--tool" ]] && tool="$2"
: "${OS_CLOUD:?set OS_CLOUD to the clouds.yaml entry of stack 20}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
edge="${root}/stacks/20-public-edge"
routes_file="${edge}/routes.auto.tfvars.json"

# 1. Routes of the applied tenant stacks (a stack without a `routes` output is skipped).
routes='{}'
for stack in "${root}"/stacks/30-tenants/*/; do
  out=""
  if [[ -f "${stack}/routes.json" ]]; then
    out=$(cat "${stack}/routes.json")
  elif [[ -d "${stack}/.terraform" ]]; then
    out=$("${tool}" -chdir="${stack}" output -json routes 2>/dev/null) || out=""
  fi
  if [[ -n "${out}" ]]; then
    echo "routes from $(basename "${stack}"): $(jq -r 'keys | join(", ")' <<<"${out}")"
    routes=$(jq -s '.[0] * .[1]' <(echo "${routes}") <(echo "${out}"))
  fi
done
new=$(jq '{routes: .}' <<<"${routes}")

if [[ -f "${routes_file}" ]] && diff -q <(jq -S . "${routes_file}") <(jq -S . <<<"${new}") >/dev/null; then
  echo "routes unchanged: nothing to do"
  exit 0
fi
echo "${new}" > "${routes_file}"

# 2. Replace the entry point instances one at a time.
lb_id=$("${tool}" -chdir="${edge}" output -json load_balancer | jq -r .id)

wait_members_online() {
  for _ in $(seq 1 60); do
    statuses=$(openstack loadbalancer pool list --loadbalancer "${lb_id}" -f value -c id |
      xargs -I{} openstack loadbalancer member list {} -f value -c operating_status)
    if [[ -n "${statuses}" ]] && ! grep -qv ONLINE <<<"${statuses}"; then
      return 0
    fi
    sleep 10
  done
  echo "load balancer members not ONLINE after 10 minutes" >&2
  return 1
}

for instance in $("${tool}" -chdir="${edge}" output -json instances | jq -r 'keys[]'); do
  echo "replacing ${instance}"
  "${tool}" -chdir="${edge}" apply -auto-approve -input=false \
    -replace="module.edge.module.instance[\"${instance}\"].openstack_compute_instance_v2.this"
  wait_members_online
done
echo "routes published: $(jq -r '.routes | keys | join(", ")' <<<"${new}")"
