# Phase 1: credentials, planes, test fixtures, entry point, tenants without Kubernetes.

step_prep() {
  cluster_credential "${CLOUD_PUBLISHED_CLUSTER}" "${W}/published-clouds.yaml"
  cluster_credential "${CLOUD_K8S_SHARED_CLUSTER}" "${W}/shared-clouds.yaml"
  cat > "${W}/ssh.cfg" <<CONFIG
Host *
  User ${SSH_USER}
  IdentityFile ${SSH_KEY}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
CONFIG
}

# The application credential given to a cluster: a clouds.yaml entry renamed openstack.
cluster_credential() {  # cluster_credential <entry> <file>
  python3 - "$1" "$2" <<'PY'
import os, sys, yaml
entry = dict(yaml.safe_load(open(os.path.expanduser("~/.config/openstack/clouds.yaml")))["clouds"][sys.argv[1]])
if entry.pop("cacert", None):
    entry["cacert"] = "/opt/platform/cacert.pem"
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    yaml.safe_dump({"clouds": {"openstack": entry}}, f)
PY
}

project_id() {
  python3 -c "import openstack, sys; print(openstack.connect(cloud=sys.argv[1], load_envvars=False).current_project_id)" "$1"
}

step_planes() {
  local planes=${PLANES_GATEWAY}
  [[ "${mode}" == interface ]] && planes=${PLANES_INTERFACE}
  local shared edge web isolated published k8s_shared
  shared=$(project_id "${CLOUD_SHARED}")
  edge=$(project_id "${CLOUD_EDGE}")
  web=$(project_id "${CLOUD_WEB}")
  isolated=$(project_id "${CLOUD_ISOLATED}")
  published=$(project_id "${CLOUD_PUBLISHED}")
  k8s_shared=$(project_id "${CLOUD_K8S_SHARED}")

  cat > "${PLANES}/terraform.tfvars" <<VARS
cloud = "${CLOUD_HUB}"
site  = "${SITE}"
planes = {
${planes}
}
attachments = {
  receiver         = { project_id = "${shared}", cidr = "10.34.0.0/28", planes = { observability = "shared" } }
  internal-service = { project_id = "${shared}", cidr = "10.35.0.0/28", planes = { internal = "shared" } }
  acme             = { project_id = "${shared}", cidr = "10.37.0.0/28", planes = { internal = "shared" } }
  edge             = { project_id = "${edge}", cidr = "10.20.0.0/24", planes = { publication = "shared", observability = "tenant" } }
  web              = { project_id = "${web}", cidr = "10.21.0.0/24", planes = { publication = "tenant", observability = "tenant", internal = "tenant" } }
  isolated         = { project_id = "${isolated}", cidr = "10.22.0.0/24", planes = { observability = "tenant" } }
  published        = { project_id = "${published}", cidr = "10.24.0.0/24", planes = { publication = "tenant", observability = "tenant", internal = "tenant" } }
  k8s-shared       = { project_id = "${k8s_shared}", cidr = "10.36.0.0/24", planes = { internal = "shared", observability = "tenant" } }
}
tenant_ranges = {
  publication   = ["10.21.0.0/16", "10.22.0.0/15", "10.24.0.0/14"]
  observability = ["10.20.0.0/14", "10.24.0.0/14", "10.36.0.0/24"]
  internal      = ["10.20.0.0/14", "10.24.0.0/14"]
}
VARS
  apply_stack "${PLANES}"
}

step_receiver() {
  set_inputs "${RECEIVER}" plane_attachment:="$(attachment receiver)"
  apply_stack "${RECEIVER}"
  output_raw "${RECEIVER}" receiver_url > "${W}/receiver_url"
  wait_for_instances "$(output_raw "${RECEIVER}" bastion)" "$(output_raw "${RECEIVER}" address)"
}

step_acme() {
  set_inputs "${ACME}" plane_attachment:="$(attachment acme)"
  apply_stack "${ACME}"
  output_raw "${ACME}" root_certificate > "${W}/root.pem"
  wait_for_instances "$(output_raw "${ACME}" bastion)" "$(output_raw "${ACME}" instance_address)"
}

step_edge() {
  rm -f "${ENTRY_POINT}/domains.auto.tfvars.json"
  set_inputs "${ENTRY_POINT}" cloud="${CLOUD_EDGE}" plane_attachment:="$(attachment edge)" monitoring:="$(monitoring)"
  apply_stack "${ENTRY_POINT}"
  output_json "${ENTRY_POINT}" publication_sources > "${W}/edge_sources.json"
  # shellcheck disable=SC2046
  wait_for_instances "$(output_raw "${ENTRY_POINT}" bastion)" $(instances_of "${ENTRY_POINT}")
}

step_web() {
  set_inputs "${VM}" cloud="${CLOUD_WEB}" plane_attachment:="$(attachment web)" monitoring:="$(monitoring)" \
    edge_sources:="$(edge_sources)" certificates:="$(certificates_of web)"
  apply_stack "${VM}"
  # shellcheck disable=SC2046
  wait_for_instances "$(output_raw "${VM}" bastion)" $(instances_of "${VM}")
}

step_isolated() {
  set_inputs "${ISOLATED}" cloud="${CLOUD_ISOLATED}" plane_attachment:="$(attachment isolated)" monitoring:="$(monitoring)"
  apply_stack "${ISOLATED}"
  # shellcheck disable=SC2046
  wait_for_instances "$(output_raw "${ISOLATED}" bastion)" $(instances_of "${ISOLATED}")
}

# After the first publication, new domains are published under load: no request may fail.
step_publish() {
  local status=0 load="" load_status=0
  rm -f "${W}/stop-load"
  if [[ -f "${W}/published-once" ]]; then
    load_during_publication & load=$!
  fi
  OS_CLOUD=${CLOUD_EDGE} show scripts/publish-domains.sh --tool "${TOOL}" || status=$?
  touch "${W}/stop-load" "${W}/published-once"
  if [[ -n "${load}" ]]; then wait "${load}" || load_status=$?; fi
  [[ ${status} -eq 0 && ${load_status} -eq 0 ]]
}

load_during_publication() {
  local address ok=0 failed=0
  address=$(output_json "${ENTRY_POINT}" load_balancer | jq -r .floating_ip)
  while [[ ! -f "${W}/stop-load" ]]; do
    if curl -sf -o /dev/null --cacert "${W}/root.pem" --max-time 5 --resolve "site-a.example.org:443:${address}" https://site-a.example.org/; then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
    fi
    sleep 0.2
  done
  echo "requests during the publication: ${ok} ok, ${failed} failed" | tee -a "${W}/https.txt"
  [[ ${failed} -eq 0 ]]
}
