#!/usr/bin/env bash
# Publish the routes of the tenants on the public entry point (stack 20).
#
# Collects the `routes` output of every applied stack under stacks/30-tenants, writes them to
# stacks/20-public-edge/routes.auto.tfvars.json and, when they changed, replaces the entry point
# instances one at a time: routes are written by cloud-init, and the load balancer keeps a healthy
# member while the other instance is replaced.
#
#     OS_CLOUD=<entry of stack 20> scripts/publish-routes.sh [--tool tofu|terraform]
#
# Needs jq and Python 3 with openstacksdk (to wait for the load balancer members). Safe to run
# again after a failure: an interrupted publication is resumed.
set -euo pipefail

tool=tofu
[[ "${1:-}" == "--tool" ]] && tool="$2"
: "${OS_CLOUD:?set OS_CLOUD to the clouds.yaml entry of stack 20}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
edge="${root}/stacks/20-public-edge"
routes_file="${edge}/routes.auto.tfvars.json"
pending="${edge}/.routes-publication-pending"

# 1. Routes of the applied tenant stacks (a stack without a `routes` output is skipped).
routes='{}'
for stack in "${root}"/stacks/30-tenants/*/; do
  out=""
  if [[ -d "${stack}/.terraform" ]]; then
    out=$("${tool}" -chdir="${stack}" output -json routes 2>/dev/null) || out=""
  fi
  if [[ -n "${out}" ]]; then
    echo "routes from $(basename "${stack}"): $(jq -r 'keys | join(", ")' <<<"${out}")"
    routes=$(jq -s '.[0] * .[1]' <(echo "${routes}") <(echo "${out}"))
  fi
done
new=$(jq '{routes: .}' <<<"${routes}")

if [[ ! -f "${pending}" && -f "${routes_file}" ]] && diff -q <(jq -S . "${routes_file}") <(jq -S . <<<"${new}") >/dev/null; then
  echo "routes unchanged: nothing to do"
  exit 0
fi
touch "${pending}"
echo "${new}" > "${routes_file}"

# 2. Replace the entry point instances one at a time.
lb_id=$("${tool}" -chdir="${edge}" output -json load_balancer | jq -r .id)

wait_members_online() {
  python3 - "${lb_id}" <<'PY'
import sys, time, openstack
conn = openstack.connect(cloud=None)  # OS_CLOUD
lb = sys.argv[1]
for _ in range(60):
    status = [m.operating_status for p in conn.load_balancer.pools(loadbalancer_id=lb)
              for m in conn.load_balancer.members(p)]
    if status and all(s == "ONLINE" for s in status):
        sys.exit(0)
    time.sleep(10)
sys.exit("load balancer members not ONLINE after 10 minutes")
PY
}

for instance in $("${tool}" -chdir="${edge}" output -json instances | jq -r 'keys[]'); do
  echo "replacing ${instance}"
  "${tool}" -chdir="${edge}" apply -auto-approve -input=false \
    -replace="module.edge.module.instance[\"${instance}\"].openstack_compute_instance_v2.this"
  wait_members_online
done
rm -f "${pending}"
echo "routes published: $(jq -r '.routes | keys | join(", ")' <<<"${new}")"
