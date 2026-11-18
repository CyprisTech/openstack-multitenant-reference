# Phase 4: nothing drifted, then nothing left.

step_plans() {
  local stack plan drift=0
  : > "${W}/plans.txt"
  for stack in "${PLANES}" "${ENTRY_POINT}" "${VM}" "${ISOLATED}" "${PUBLISHED}" "${RECEIVER}" "${INTERNAL_SERVICE}" "${ACME}"; do
    plan=0
    "${TOOL}" -chdir="${stack}" plan -detailed-exitcode -no-color >/dev/null 2>&1 || plan=$?
    echo "${stack} plan exit=${plan}" | tee -a "${W}/plans.txt"
    [[ ${plan} -eq 0 ]] || drift=1
  done
  [[ ${drift} -eq 0 ]]
}

# The clusters first: Cluster API deletes their servers and load balancers. Goes on after a failure
# to remove as much as possible, then reports it.
step_teardown() {
  local stack failed=0
  # The next campaign publishes for the first time again: no load during that publication.
  rm -f "${W}/published-once"
  delete_cluster "${SHARED}" "${SHARED_KUBECONFIG}" || failed=1
  delete_cluster "${PUBLISHED}" "${PUBLISHED_KUBECONFIG}" || failed=1
  for stack in "${SHARED}" "${INTERNAL_SERVICE}" "${PUBLISHED}" "${ISOLATED}" "${VM}" "${ENTRY_POINT}" "${RECEIVER}" "${ACME}" "${PLANES}"; do
    destroy_stack "${stack}" || { echo "DESTROY FAILED: ${stack}"; failed=1; }
  done
  [[ ${failed} -eq 0 ]]
}

# Nothing left in the projects of the campaign: servers, load balancers, floating IPs, routers,
# networks, ports, security groups (but default), volumes, server groups. Images are kept (the
# Kubernetes node image).
step_leftovers() {
  local cloud kind column count total=0 project
  local -a os
  for cloud in $(printf '%s\n' "${CLOUD_HUB:-}" "${CLOUD_SHARED:-}" "${CLOUD_EDGE:-}" "${CLOUD_WEB:-}" "${CLOUD_ISOLATED:-}" \
    "${CLOUD_PUBLISHED:-}" "${CLOUD_K8S_SHARED:-}" | grep -v '^$' | sort -u); do
    os=(openstack --os-cloud "${cloud}")
    [[ -n "${CA_CERT:-}" ]] && os+=(--os-cacert "${CA_CERT}")
    project=$("${os[@]}" token issue -f value -c project_id)
    for kind in "server list" "loadbalancer list" "floating ip list" "router list" "volume list" "server group list" \
      "network list --project ${project}" "port list --project ${project}"; do
      # A listing that fails (a missing client plugin, an API error) is a failed check, not zero objects.
      column=ID; [[ ${kind} == loadbalancer* ]] && column=id   # the Octavia plugin names its columns in lower case
      # shellcheck disable=SC2086
      if ! ids=$("${os[@]}" ${kind} -f value -c "${column}" 2>/dev/null); then
        echo "CHECK FAILED ${cloud}: ${kind%% --project*} (the listing itself failed)"; total=$((total + 1)); continue
      fi
      count=$(grep -c . <<<"${ids}" || true)
      [[ ${count} -eq 0 ]] || { echo "LEFTOVER ${cloud}: ${count} from ${kind%% --project*}"; total=$((total + count)); }
    done
    count=$("${os[@]}" security group list --project "${project}" -f value -c Name 2>/dev/null | grep -vxc default || true)
    [[ ${count} -eq 0 ]] || { echo "LEFTOVER ${cloud}: ${count} security groups"; total=$((total + count)); }
  done
  echo "leftovers: ${total}" | tee -a "${W}/plans.txt"
  [[ ${total} -eq 0 ]]
}
