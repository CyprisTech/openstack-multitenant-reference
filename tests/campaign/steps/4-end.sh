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
  delete_cluster "${SHARED}" "${SHARED_KUBECONFIG}" || failed=1
  delete_cluster "${PUBLISHED}" "${PUBLISHED_KUBECONFIG}" || failed=1
  for stack in "${SHARED}" "${INTERNAL_SERVICE}" "${PUBLISHED}" "${ISOLATED}" "${VM}" "${ENTRY_POINT}" "${RECEIVER}" "${ACME}" "${PLANES}"; do
    destroy_stack "${stack}" || { echo "DESTROY FAILED: ${stack}"; failed=1; }
  done
  [[ ${failed} -eq 0 ]]
}
