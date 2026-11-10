# Phase 3: the Kubernetes tenant published on the entry point, and the acceptance tests.

step_k8s() {
  set_inputs "${PUBLISHED}" cloud="${CLOUD_PUBLISHED}" plane_attachment:="$(attachment published)" monitoring:="$(monitoring)" \
    edge_sources:="$(edge_sources)" certificates:="$(certificates_of published)" bootstrap:=true
  apply_stack "${PUBLISHED}"
  wait_for_bootstrap "${PUBLISHED}"
}

step_cluster() {
  create_cluster "${PUBLISHED}" "${W}/published-clouds.yaml" "${PUBLISHED_KUBECONFIG}"
}

# The fixture of an internal service, open to the Kubernetes tenant only.
step_internal() {
  set_inputs "${INTERNAL_SERVICE}" cloud="${CLOUD_SHARED}" plane_attachment:="$(attachment internal-service)" \
    allowed_sources:="$(output_json "${PUBLISHED}" internal_sources)"
  apply_stack "${INTERNAL_SERVICE}"
}

step_tour() {
  # shellcheck disable=SC2086
  python3 tests/tour/capture.py --kubeconfig "${PUBLISHED_KUBECONFIG}" --cluster "$(cluster_name "${PUBLISHED_KUBECONFIG}")" ${CAPTURE_REPLACE:-} > "${W}/kubernetes-tour.md"
  show clusterctl describe cluster "$(cluster_name "${PUBLISHED_KUBECONFIG}")" -n platform --kubeconfig "${PUBLISHED_KUBECONFIG}"
  show kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" get machines -n platform
  show kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" get gateway,httproute,certificate -A
}

# HTTPS through the entry point to the three domains, then the isolation test.
step_accept() {
  local address domain
  demo_manifest "${PUBLISHED}/demo/whoami.yaml" | kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" apply -f - >/dev/null
  kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" -n demo rollout status deploy/whoami
  for _ in $(seq 60); do
    [[ -n "$(kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" ]] && break
    sleep 10
  done
  sleep 30   # the routes reach Traefik within seconds; the agents push every 30 s

  address=$(output_json "${ENTRY_POINT}" load_balancer | jq -r .floating_ip)
  for domain in "site-a.${TEST_ZONE}" "site-b.${TEST_ZONE}" "apps.published.${TEST_ZONE}"; do
    https_probe "${domain}" "${address}"
  done
  isolation_test published
}

# The vm tenant exposed directly (exposure = "public"): HTTPS on its own public address, no router
# on the publication plane, the entry point no longer reaches its instances. Then back to the
# entry point.
step_direct() {
  local inputs="${VM}/mode.auto.tfvars.json" address bastion edge instance results
  cp "${inputs}" "${W}/vm.inputs.bak"
  jq '.exposure = "public"' "${W}/vm.inputs.bak" > "${inputs}"
  run_apply "${VM}"
  address=$(output_raw "${VM}" service_address | cut -d: -f1)
  echo "service address, exposed directly: ${address}" | tee -a "${W}/https.txt"
  results=$(https_probe "site-a.${TEST_ZONE}" "${address}") || { echo "${results}"; restore_vm; return 1; }

  comment "No router on the publication plane: the entry point no longer reaches the instances"
  bastion=$(output_raw "${ENTRY_POINT}" bastion)
  edge=$(instances_of "${ENTRY_POINT}" | head -1)
  instance=$(first_instance_of "${VM}")
  if on_instance "${bastion}" "${edge}" "timeout 4 bash -c '</dev/tcp/${instance}/443'" 2>/dev/null; then
    echo "ENTRY POINT STILL REACHES ${instance}"; restore_vm; return 1
  fi
  echo "entry point -> ${instance}:443 closed" | tee -a "${W}/https.txt"
  restore_vm
}

restore_vm() {
  comment "Back to the entry point"
  cp "${W}/vm.inputs.bak" "${VM}/mode.auto.tfvars.json"
  run_apply "${VM}"
}

step_transit() {
  apply_stack "${PLANES}"
  output_json "${PLANES}" transit
}

# Interface mode: a tenant adds a route to another tenant through the transit router. The
# connections stay closed: the security groups decide, not the routes.
step_hostile() {
  [[ "${mode}" == interface ]] || { echo "interface mode only"; return 0; }
  local inputs="${ISOLATED}/mode.auto.tfvars.json" bastion instance target
  cp "${inputs}" "${W}/isolated.inputs.bak"
  jq --arg hop "${HOSTILE_NEXT_HOP}" '.plane_attachment.observability.routes += [{destination: "10.21.0.0/24", next_hop: $hop}]' \
    "${W}/isolated.inputs.bak" > "${inputs}"
  run_apply "${ISOLATED}"

  bastion=$(output_raw "${ISOLATED}" bastion)
  instance=$(instances_of "${ISOLATED}")
  target=$(first_instance_of "${VM}")
  wait_for_instances "${bastion}" "${instance}" >/dev/null
  on_instance "${bastion}" "${instance}" "sudo networkctl renew ens3; sleep 4; ip route | grep 10.21
    for port in 443 22 9100; do
      timeout 4 bash -c \"</dev/tcp/${target}/\${port}\" 2>/dev/null && echo \"\${port} OPEN\" || echo \"\${port} closed\"
    done" | tee "${W}/hostile.txt"

  cp "${W}/isolated.inputs.bak" "${inputs}"
  run_apply "${ISOLATED}"
  ! grep -q OPEN "${W}/hostile.txt"
}
