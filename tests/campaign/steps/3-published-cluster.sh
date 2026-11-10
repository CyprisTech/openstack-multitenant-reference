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
