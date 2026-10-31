#!/usr/bin/env bash
# Publish the domains of the tenants on the public entry point (stack shared/entry-point).
#
# Collects the `published_domains` output of every applied stack under stacks/tenants, writes them
# to stacks/shared/entry-point/domains.auto.tfvars.json and, when they changed, replaces the entry point
# instances one at a time: the routing of Traefik is written by cloud-init, and the load balancer keeps a healthy
# member while the other instance is replaced.
#
#     OS_CLOUD=<entry of the entry point's project> scripts/publish-domains.sh [--tool tofu|terraform] [--allow-empty]
#
# Needs jq and Python 3 with openstacksdk (to wait for the load balancer members). Safe to run
# again after a failure: an interrupted publication is resumed.
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
pending="${edge}/.domains-publication-pending"

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

# An empty publication would replace the instances with a configuration routing nothing.
if [[ "${allow_empty}" != true && "$(jq 'length' <<<"${domains}")" == 0 && -f "${domains_file}" \
      && "$(jq '.domains | length' "${domains_file}")" != 0 ]]; then
  echo "no domain found, while domains are published: refusing to remove them all (--allow-empty to force)" >&2
  exit 1
fi

if [[ ! -f "${pending}" && -f "${domains_file}" ]] && diff -q <(jq -S . "${domains_file}") <(jq -S . <<<"${new}") >/dev/null; then
  echo "domains unchanged: nothing to do"
  exit 0
fi
touch "${pending}"
echo "${new}" > "${domains_file}"

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
echo "domains published: $(jq -r '.domains | keys | join(", ")' <<<"${new}")"
