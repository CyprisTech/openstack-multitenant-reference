# Helpers shared by the steps of the campaign (sourced by run.sh).

# The stacks and fixtures, in the order of the architecture.
PLANES=stacks/shared/planes
ENTRY_POINT=stacks/shared/entry-point
VM=stacks/tenants/vm
ISOLATED=stacks/tenants/isolated
PUBLISHED=stacks/tenants/kubernetes
SHARED=stacks/shared/kubernetes
RECEIVER=tests/fixtures/receiver
ACME=tests/fixtures/acme
INTERNAL_SERVICE=tests/fixtures/internal-service

# --- Output ---------------------------------------------------------------------------------------

heading() { printf '\n\033[1;34m== [%s %s] %s\033[0m\n' "$(date -u +%T)" "${mode}" "$*"; }
comment() { printf '\n\033[1;33m# %s\033[0m\n' "$*"; }
timing() { echo "$(date -u +%T) $*" >> "${W}/timings.txt"; }

# Print a command before running it: the recordings read like a terminal session.
show() {
  printf '\033[1;32m$\033[0m %s\n' "$*"
  "$@"
}

recording() { [[ "${RECORD:-0}" == 1 ]]; }

# --- Inputs and outputs of the stacks -------------------------------------------------------------

output_json() { "${TOOL}" -chdir="$1" output -json "$2"; }
output_raw() { "${TOOL}" -chdir="$1" output -raw "$2"; }

# The planes of an attachment, from the output of the planes stack.
attachment() { output_json "${PLANES}" attachments | jq ".\"$1\".planes"; }
# The certificates input of a tenant, from the test ACME authority.
certificates_of() { output_json "${ACME}" certificates | jq ".\"$1\""; }
monitoring() { jq -n --arg receiver "$(cat "${W}/receiver_url")" '{receiver: $receiver}'; }
edge_sources() { cat "${W}/edge_sources.json"; }

# Write the per-mode inputs of a stack. A file that tofu loads by itself, so that a plain apply
# (also the one of publish-domains.sh) uses them.
#     set_inputs <stack> name=string name:=json ...
set_inputs() {
  local stack=$1 pair key filter='{}' args=(); shift
  for pair in "$@"; do
    if [[ "${pair}" =~ ^[a-z_]+:= ]]; then
      key=${pair%%:=*}; args+=(--argjson "${key}" "${pair#*:=}")
    else
      key=${pair%%=*}; args+=(--arg "${key}" "${pair#*=}")
    fi
    filter+=" + {${key}: \$${key}}"
  done
  jq -n "${args[@]}" "${filter}" > "${stack}/mode.auto.tfvars.json"
}

# --- Apply and destroy ----------------------------------------------------------------------------

# Filtered output in a normal run, the full output of the tool in a recording.
run_apply() {
  local stack=$1 log status=0; shift
  if recording; then
    show "${TOOL}" -chdir="${stack}" apply -auto-approve -input=false "$@" || status=$?
  else
    log=$(log_of "${stack}")
    "${TOOL}" -chdir="${stack}" apply -auto-approve -input=false -no-color "$@" > "${log}" 2>&1 || status=$?
    grep -E "^Apply complete|Error|error" "${log}" || true
  fi
  return "${status}"
}

log_of() { mkdir -p "${W}/logs"; echo "${W}/logs/${1//\//-}.log"; }

# Apply a stack, then require an empty plan. REPAIR_HOOK (optional, outside this repository) may
# clean a known failure of the test cloud: it prints extra apply arguments, or fails.
apply_stack() {
  local stack=$1 start status=0 attempt=0 extra plan=0
  start=$(date +%s)
  "${TOOL}" -chdir="${stack}" init -input=false >/dev/null
  run_apply "${stack}" || status=$?
  while [[ ${status} -ne 0 && -n "${REPAIR_HOOK:-}" && ${attempt} -lt ${REPAIRS:-1} ]]; do
    attempt=$((attempt + 1))
    echo "apply failed on ${stack}: repair ${attempt}/${REPAIRS:-1}"
    extra=$("${REPAIR_HOOK}" "${stack}") || break
    status=0
    # shellcheck disable=SC2086
    run_apply "${stack}" ${extra} || status=$?
    timing "${stack} repaired (${attempt}), apply status=${status}"
  done
  [[ ${status} -eq 0 ]] || { echo "APPLY FAILED: ${stack}"; return 1; }

  "${TOOL}" -chdir="${stack}" plan -detailed-exitcode -input=false -no-color >/dev/null 2>&1 || plan=$?
  echo "${stack}: apply $(($(date +%s) - start)) s, plan after apply exit=${plan} (0 = empty)"
  timing "${stack} apply=$(($(date +%s) - start))s plan=${plan}"
  [[ ${plan} -eq 0 ]] || { echo "PLAN NOT EMPTY: ${stack}"; return 1; }
}

destroy_stack() {
  local stack=$1 start log status=0
  start=$(date +%s)
  if recording; then
    show "${TOOL}" -chdir="${stack}" destroy -auto-approve || status=$?
  else
    log=$(log_of "${stack}")
    "${TOOL}" -chdir="${stack}" destroy -auto-approve -no-color > "${log}" 2>&1 || status=$?
    grep -E "Destroy complete|Error" "${log}" || true
  fi
  timing "${stack} destroy=$(($(date +%s) - start))s status=${status}"
  return "${status}"
}

# --- Access to the instances ----------------------------------------------------------------------

remote() { ssh -F "${W}/ssh.cfg" "$@"; }
copy() { scp -F "${W}/ssh.cfg" -q "$@"; }
# Run a command on an instance through the bastion of its stack.
on_instance() {  # on_instance <bastion> <address> <command>
  remote -J "${SSH_USER}@$1" "${SSH_USER}@$2" "$3"
}
# All the instances of a stack, then the first one.
instances_of() { output_json "$1" instances | jq -r '.[]'; }
first_instance_of() { output_json "$1" instances | jq -r 'to_entries[0].value'; }

wait_for_instances() {  # wait_for_instances <bastion> <address>...
  local bastion=$1 address attempt; shift
  for address in "$@"; do
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      on_instance "${bastion}" "${address}" "hostname; cloud-init status --wait | tail -1" 2>/dev/null && continue 2
      echo "  ${address} not reachable yet (attempt ${attempt})"
      sleep 20
    done
    echo "INSTANCE NOT READY: ${address}"
    return 1
  done
}

wait_for_bootstrap() { remote -o ConnectionAttempts=30 "$(output_raw "$1" bootstrap)" "cloud-init status --wait | tail -1"; }

# --- Kubernetes -----------------------------------------------------------------------------------

# Run the creation script on the bootstrap instance, then fetch the kubeconfig.
create_cluster() {  # create_cluster <stack> <credential file> <cluster name> <kubeconfig>
  local stack=$1 credential=$2 name=$3 kubeconfig=$4 bootstrap start
  bootstrap=$(output_raw "${stack}" bootstrap)
  copy "${credential}" "${bootstrap}:/tmp/clouds.yaml"
  if [[ -n "${CA_CERT:-}" ]]; then copy "${CA_CERT}" "${bootstrap}:/tmp/cacert.pem"; fi
  remote "${bootstrap}" 'sudo install -m 600 /tmp/clouds.yaml /opt/platform/clouds.yaml
    if [ -f /tmp/cacert.pem ]; then sudo install -m 644 /tmp/cacert.pem /opt/platform/cacert.pem; fi
    rm -f /tmp/clouds.yaml /tmp/cacert.pem'

  start=$(date +%s)
  remote -t "${bootstrap}" sudo /opt/platform/create-cluster.sh
  timing "create-cluster ${name} $(($(date +%s) - start))s"

  remote "${bootstrap}" sudo cat "/opt/platform/${name}.kubeconfig" > "${kubeconfig}"
  chmod 600 "${kubeconfig}"
  show kubectl --kubeconfig "${kubeconfig}" get nodes -o wide
  show kubectl --kubeconfig "${kubeconfig}" get svc -A --field-selector spec.type=LoadBalancer
}

# Admit the bootstrap instance on the API again, then delete the cluster from it. Does nothing if
# the cluster is not deployed.
delete_cluster() {  # delete_cluster <stack> <kubeconfig>
  local stack=$1 kubeconfig=$2 bootstrap start
  bootstrap=$(output_raw "${stack}" bootstrap 2>/dev/null) || return 0
  [[ -n "${bootstrap}" && "${bootstrap}" != null ]] || return 0
  kubectl --kubeconfig "${kubeconfig}" get cluster -A >/dev/null 2>&1 || return 0
  output_json "${stack}" manifests | jq -r '."cluster.yaml"' | sed "s|BOOTSTRAP_SOURCE|${bootstrap}/32|" \
    | kubectl --kubeconfig "${kubeconfig}" apply -f - || return 1
  sleep 60
  start=$(date +%s)
  remote -t "${bootstrap}" sudo /opt/platform/delete-cluster.sh || return 1
  timing "delete-cluster ${stack} $(($(date +%s) - start))s"
}

# --- Checks ---------------------------------------------------------------------------------------

# The executable matrix, with the cluster that is deployed. Its output is kept for the results.
isolation_test() {  # isolation_test <shared|published>
  local args=(--receiver "${RECEIVER}" --user "${SSH_USER}" --key "${SSH_KEY}" --acme "${ACME}" --tool "${TOOL}")
  case $1 in
    shared) args+=(--shared-kubeconfig "${SHARED_KUBECONFIG}") ;;
    published) args+=(--published-kubeconfig "${PUBLISHED_KUBECONFIG}" --internal-service "${INTERNAL_SERVICE}") ;;
  esac
  show python3 tests/isolation/check.py "${args[@]}" 2>&1 | tee "${W}/isolation-$1.txt"
  return "${PIPESTATUS[0]}"
}

# HTTPS twelve times through an address, certificate verified, results counted. Fails if one
# request failed.
https_probe() {  # https_probe <domain> <address>
  local domain=$1 address=$2 results
  results=$(for _ in $(seq 12); do
    curl -s --cacert "${W}/root.pem" --max-time 10 --resolve "${domain}:443:${address}" "https://${domain}/" \
      | grep -E "^host=|^Hostname|X-Real-Ip" || echo FAIL
  done | sed 's/server=[^ ]*//' | sort | uniq -c | sed "s|^|${domain} |")
  echo "${results}" | tee -a "${W}/https.txt"
  ! grep -q FAIL <<<"${results}"
}
