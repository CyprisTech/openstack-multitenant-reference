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

# 2. Replace the entry point instances one at a time. An instance whose members are not ONLINE is
#    replaced first: it serves nothing. A healthy instance is replaced only while every other
#    instance is healthy, so that the load balancer always keeps a member.
lb_id=$("${tool}" -chdir="${edge}" output -json load_balancer | jq -r .id)
instances=$("${tool}" -chdir="${edge}" output -json instances)   # name => address on the edge network

# Health of each instance: "healthy" when all its members, in every pool, are ONLINE.
health() {
  python3 - "${lb_id}" "${instances}" <<'PY'
import json, sys, openstack
conn = openstack.connect(cloud=None)  # OS_CLOUD
lb, instances = sys.argv[1], json.loads(sys.argv[2])
status = {}
for p in conn.load_balancer.pools(loadbalancer_id=lb):
    for m in conn.load_balancer.members(p):
        status.setdefault(m.address, []).append(m.operating_status)
for name, ip in instances.items():
    s = status.get(ip, [])
    print(name, "healthy" if s and all(x == "ONLINE" for x in s) else "unhealthy")
PY
}

wait_healthy() {  # $1: instance name; 10 minutes at most
  for _ in $(seq 60); do
    health | grep -qx "$1 healthy" && return 0
    sleep 10
  done
  echo "$1: load balancer members not ONLINE after 10 minutes (check cloud-init on the instance)" >&2
  return 1
}

order=$(health | sort -k2,2r | awk '{print $1}')   # unhealthy first
for instance in ${order}; do
  if health | grep -qx "${instance} healthy" && health | grep -v "^${instance} " | grep -q unhealthy; then
    echo "refusing to replace ${instance}: it is the only healthy instance; fix the others first" >&2
    exit 1
  fi
  echo "replacing ${instance}"
  "${tool}" -chdir="${edge}" apply -auto-approve -input=false \
    -replace="module.edge.module.instance[\"${instance}\"].openstack_compute_instance_v2.this"
  wait_healthy "${instance}"
done
rm -f "${pending}"
echo "routes published: $(jq -r '.routes | keys | join(", ")' <<<"${new}")"
