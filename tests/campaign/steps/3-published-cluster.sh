# Phase 3: the published cluster behind the entry point, and the acceptance tests.

step_k8s() {
  set_inputs "${PUBLISHED}" cloud="${CLOUD_PUBLISHED}" plane_attachment:="$(attachment published)" monitoring:="$(monitoring)" \
    edge_sources:="$(edge_sources)" certificates:="$(certificates_of published)" bootstrap:=true
  apply_stack "${PUBLISHED}"
  wait_for_bootstrap "${PUBLISHED}"
}

step_cluster() {
  create_cluster "${PUBLISHED}" "${W}/published-clouds.yaml" "${PUBLISHED_KUBECONFIG}"
}

# The internal service, created closed in the foundation (step internal), is opened to the
# Kubernetes tenant once it exists: a change of its consumers, in place.
step_internal_open() {
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
  scene_begin "${VM}"
  jq '.exposure = "public"' "$(scene_backup "${VM}")" > "${inputs}"
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
  local status=0 domain address
  comment "Back to the entry point"
  scene_end "${VM}"
  # The router on publication is new: interface mode routes to it through the transit router.
  run_apply "${VM}" && step_transit >/dev/null && PUBLISH_LOAD=0 step_publish && scene_done "${VM}" || status=1
  # The load balancer existed before the change: it must answer the entry point again, through
  # the new router on publication (the routes are on the tenant's transit router, not copied
  # into the load balancer). Once the entry point answers steadily, every request must succeed.
  address=$(output_json "${ENTRY_POINT}" load_balancer | jq -r .floating_ip)
  for domain in "site-a.${TEST_ZONE}" "site-b.${TEST_ZONE}"; do
    wait_https "${domain}" "${address}" && https_probe "${domain}" "${address}" || status=1
  done
  return "${status}"
}

# The published cluster exposed directly (exposure = "public"): the ingress moves to a public
# floating IP once the add-ons are applied again, HTTPS there with the certificate checked, the
# entry point no longer reaches the cluster. Then back to the entry point, republished.
step_direct_k8s() {
  local inputs="${PUBLISHED}/mode.auto.tfvars.json" before address status=0
  # The scene answers with the demo application: deploy it when the accept step has not run.
  demo_manifest "${PUBLISHED}/demo/whoami.yaml" | kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" apply -f - >/dev/null
  kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" -n demo rollout status deploy/whoami >/dev/null || return 1
  before=$(output_raw "${PUBLISHED}" service_address | cut -d: -f1)
  scene_begin "${PUBLISHED}"
  jq '.exposure = "public"' "$(scene_backup "${PUBLISHED}")" > "${inputs}"
  if run_apply "${PUBLISHED}" && apply_addons; then
    address=$(output_raw "${PUBLISHED}" service_address | cut -d: -f1)
    echo "ingress, exposed directly: ${address}" | tee -a "${W}/https.txt"
    https_probe "apps.published.${TEST_ZONE}" "${address}" || status=1

    comment "The entry point no longer reaches the cluster"
    if on_instance "$(output_raw "${ENTRY_POINT}" bastion)" "$(instances_of "${ENTRY_POINT}" | head -1)" \
      "timeout 4 bash -c '</dev/tcp/${before}/443'" 2>/dev/null; then
      echo "ENTRY POINT STILL REACHES ${before}"; status=1
    else
      echo "entry point -> ${before}:443 closed" | tee -a "${W}/https.txt"
    fi
  else
    status=1
  fi

  comment "Back to the entry point"
  scene_end "${PUBLISHED}"
  run_apply "${PUBLISHED}" && apply_addons && step_transit >/dev/null && step_publish && scene_done "${PUBLISHED}" || status=1
  address=$(output_json "${ENTRY_POINT}" load_balancer | jq -r .floating_ip)
  wait_https "apps.published.${TEST_ZONE}" "${address}" && https_probe "apps.published.${TEST_ZONE}" "${address}" || status=1
  return "${status}"
}

# The ingress settings are in the cluster's add-ons: apply them again after a change of the stack,
# then wait for the Service to get the address of the stack.
apply_addons() {
  local address
  address=$(output_raw "${PUBLISHED}" service_address | cut -d: -f1)
  "${TOOL}" -chdir="${PUBLISHED}" output -json manifests | jq -r '."addons.yaml"' \
    | kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" apply -f - >/dev/null || return 1
  for _ in $(seq 60); do
    [[ "$(kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == "${address}" ]] && {
      show kubectl --kubeconfig "${PUBLISHED_KUBECONFIG}" -n traefik get svc traefik
      return 0
    }
    sleep 10
  done
  echo "the ingress Service did not get ${address}"; return 1
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
  scene_begin "${ISOLATED}"
  jq --arg hop "${HOSTILE_NEXT_HOP}" '.plane_attachment.observability.routes += [{destination: "10.21.0.0/24", next_hop: $hop}]' \
    "$(scene_backup "${ISOLATED}")" > "${inputs}"
  run_apply "${ISOLATED}"

  bastion=$(output_raw "${ISOLATED}" bastion)
  instance=$(instances_of "${ISOLATED}")
  target=$(first_instance_of "${VM}")
  wait_for_instances "${bastion}" "${instance}" >/dev/null
  # The route is on the tenant's transit router (ADR-0013): it applies at once, no DHCP renewal.
  on_instance "${bastion}" "${instance}" "for port in 443 22 9100; do
      timeout 4 bash -c \"</dev/tcp/${target}/\${port}\" 2>/dev/null && echo \"\${port} OPEN\" || echo \"\${port} closed\"
    done" | tee "${W}/hostile.txt"

  scene_end "${ISOLATED}"
  run_apply "${ISOLATED}" && scene_done "${ISOLATED}"
  ! grep -q OPEN "${W}/hostile.txt"
}
