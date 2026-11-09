# Phase 2: the Kubernetes cluster for shared services, tested, then removed.

shared_service_address() { output_json "${SHARED}" services | jq -r .ingress | cut -d: -f1; }

step_k8s_shared() {
  set_inputs "${SHARED}" cloud="${CLOUD_K8S_SHARED}" plane_attachment:="$(attachment k8s-shared)" monitoring:="$(monitoring)" \
    consumers:="$(output_json "${VM}" internal_sources)" certificates:="$(certificates_of shared)" bootstrap:=true
  apply_stack "${SHARED}"
  wait_for_bootstrap "${SHARED}"
}

step_cluster_shared() {
  create_cluster "${SHARED}" "${W}/shared-clouds.yaml" "${SITE}-shared" "${SHARED_KUBECONFIG}"
  show kubectl --kubeconfig "${SHARED_KUBECONFIG}" apply -f "${SHARED}/demo/whoami.yaml" -f "${SHARED}/demo/echo.yaml"
  kubectl --kubeconfig "${SHARED_KUBECONFIG}" -n whoami rollout status deploy/whoami
  kubectl --kubeconfig "${SHARED_KUBECONFIG}" -n echo rollout status deploy/echo
}

# The records of the internal names, written in the test zone. An organisation writes them with
# its DNS provider, from the same output.
step_names() {
  local zone name address bastion authority
  zone=$(output_raw "${ACME}" zone)
  bastion=$(output_raw "${ACME}" bastion)
  authority=$(output_raw "${ACME}" instance_address)
  output_json "${SHARED}" domains | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r name address; do
    show on_instance "${bastion}" "${authority}" \
      "sudo knotc zone-begin ${zone} && sudo knotc zone-set ${zone} ${name}. 300 A ${address} && sudo knotc zone-commit ${zone}"
  done
}

step_tour_shared() {
  # shellcheck disable=SC2086
  python3 tests/tour/capture.py --kubeconfig "${SHARED_KUBECONFIG}" --cluster "${SITE}-shared" ${CAPTURE_REPLACE:-} > "${W}/tour-shared.md"
  show kubectl --kubeconfig "${SHARED_KUBECONFIG}" get nodes,svc -A
  show kubectl --kubeconfig "${SHARED_KUBECONFIG}" get gateway,httproute,certificate -A
  show kubectl --kubeconfig "${SHARED_KUBECONFIG}" get networkpolicy -A
}

# A consumer finds the service by its name in the zone, and reaches it over HTTPS with the root it
# received at boot (certificates.ca_bundle).
step_accept_shared() {
  local service bastion vm results resolved
  service=$(shared_service_address)
  bastion=$(output_raw "${VM}" bastion)
  vm=$(first_instance_of "${VM}")
  resolved=$(on_instance "${bastion}" "${vm}" "dig +short @$(output_raw "${ACME}" address) services.example.org A | tail -1")
  echo "services.example.org resolves to ${resolved}" | tee -a "${W}/https.txt"
  [[ "${resolved}" == "${service}" ]]
  results=$(for _ in 1 2 3 4 5 6; do
    on_instance "${bastion}" "${vm}" "curl -s --cacert /etc/lego/ca.pem --max-time 10 --resolve services.example.org:443:${service} https://services.example.org/ | grep -E '^Hostname' || echo FAIL"
  done | sort | uniq -c | sed 's/^/shared https /')
  echo "${results}" | tee -a "${W}/https.txt"
  ! grep -q FAIL <<<"${results}"
  isolation_test shared
}

try_shared_service() {
  local status=0
  show curl -sS --cacert "${W}/root.pem" --max-time 8 --resolve "services.example.org:443:$1" https://services.example.org/ || status=$?
  echo "curl exit=${status}"
  return "${status}"
}

apply_shared_manifests() {
  output_json "${SHARED}" manifests | jq -r '."addons.yaml", ."services.yaml"' | kubectl --kubeconfig "${SHARED_KUBECONFIG}" apply -f -
}

# Closed by default, then a range of users admitted: CONSUMER_CIDR, this machine as the cluster sees it.
step_consumer() {
  [[ -n "${CONSUMER_CIDR:-}" ]] || { echo "CONSUMER_CIDR not set: scene skipped"; return 0; }
  local inputs="${SHARED}/mode.auto.tfvars.json" service
  service=$(shared_service_address)
  cp "${inputs}" "${W}/shared.inputs.bak"

  comment "Not a declared consumer: the service stays closed"
  if try_shared_service "${service}"; then
    echo "OPEN TO AN UNDECLARED CONSUMER"
    return 1
  fi

  comment "Add a consumer: one line of configuration, apply, the two manifests"
  jq --arg cidr "${CONSUMER_CIDR}" '.consumers += [$cidr]' "${W}/shared.inputs.bak" > "${inputs}"
  run_apply "${SHARED}"
  apply_shared_manifests
  sleep 20
  try_shared_service "${service}"

  comment "Back to the declared consumers"
  cp "${W}/shared.inputs.bak" "${inputs}"
  run_apply "${SHARED}"
  apply_shared_manifests
}

step_shared_down() {
  delete_cluster "${SHARED}" "${SHARED_KUBECONFIG}"
  destroy_stack "${SHARED}"
}
