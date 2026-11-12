# Phase 2: the shared cluster (a Kubernetes cluster for shared services), tested, then removed.

shared_service_address() { output_json "${SHARED}" services | jq -r .ingress | cut -d: -f1; }

step_k8s_shared() {
  set_inputs "${SHARED}" cloud="${CLOUD_K8S_SHARED}" plane_attachment:="$(attachment k8s-shared)" monitoring:="$(monitoring)" \
    consumers:="$(output_json "${VM}" internal_sources)" certificates:="$(certificates_of shared)" bootstrap:=true
  apply_stack "${SHARED}"
  wait_for_bootstrap "${SHARED}"
}

step_cluster_shared() {
  create_cluster "${SHARED}" "${W}/shared-clouds.yaml" "${SHARED_KUBECONFIG}"
  demo_manifest "${SHARED}/demo/whoami.yaml" | kubectl --kubeconfig "${SHARED_KUBECONFIG}" apply -f -
  show kubectl --kubeconfig "${SHARED_KUBECONFIG}" apply -f "${SHARED}/demo/echo.yaml"
  kubectl --kubeconfig "${SHARED_KUBECONFIG}" -n whoami rollout status deploy/whoami
  kubectl --kubeconfig "${SHARED_KUBECONFIG}" -n echo rollout status deploy/echo
}

step_tour_shared() {
  # shellcheck disable=SC2086
  python3 tests/tour/capture.py --kubeconfig "${SHARED_KUBECONFIG}" --cluster "$(cluster_name "${SHARED_KUBECONFIG}")" ${CAPTURE_REPLACE:-} > "${W}/tour-shared.md"
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
  resolved=$(on_instance "${bastion}" "${vm}" "dig +short @${NAME_SERVER} ${SHARED_NAME} A | tail -1")
  echo "${SHARED_NAME} resolves to ${resolved}" | tee -a "${W}/https.txt"
  [[ "${resolved}" == "${service}" ]]
  results=$(for _ in 1 2 3 4 5 6; do
    on_instance "${bastion}" "${vm}" "curl -s --cacert /etc/lego/ca.pem --max-time 10 --resolve ${SHARED_NAME}:443:${service} https://${SHARED_NAME}/ | grep -E '^Hostname' || echo FAIL"
  done | sort | uniq -c | sed 's/^/shared https /')
  echo "${results}" | tee -a "${W}/https.txt"
  # Not "! grep": errexit ignores a negated command, and the step would go on.
  if grep -q FAIL <<<"${results}"; then return 1; fi
  isolation_test shared
}

try_shared_service() {
  local status=0
  show curl -sS --cacert "${W}/root.pem" --max-time 8 --resolve "${SHARED_NAME}:443:$1" https://${SHARED_NAME}/ || status=$?
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
  # The source reaches the chart, the Service, then the Octavia listeners: a minute or two.
  local attempt
  for attempt in $(seq 18); do
    curl -s -o /dev/null --cacert "${W}/root.pem" --max-time 5 --resolve "${SHARED_NAME}:443:${service}" "https://${SHARED_NAME}/" && break
    sleep 10
  done
  echo "open after about $((attempt * 10)) s"
  try_shared_service "${service}"

  comment "Back to the declared consumers"
  cp "${W}/shared.inputs.bak" "${inputs}"
  run_apply "${SHARED}"
  apply_shared_manifests
}

# Move the cluster to another application credential, as in docs/guides/kubernetes-lifecycle.md,
# then check that the cloud controller works with it: a new load balancer. Cluster API uses it
# in the next step.
step_rotate() {
  local next="${W}/next-clouds.yaml" identity conf id secret
  export KUBECONFIG=${SHARED_KUBECONFIG}
  cluster_credential "${CLOUD_K8S_SHARED_CLUSTER_NEXT}" "${next}"
  id=$(yq_credential application_credential_id "${next}")
  secret=$(yq_credential application_credential_secret "${next}")
  identity=$(kubectl -n platform get openstackcluster -o jsonpath='{.items[0].spec.identityRef.name}')

  comment "Cluster API: the secret of its identity"
  kubectl -n platform get secret "${identity}" -o json \
    | jq --arg c "$(base64 -w0 "${next}")" '.data["clouds.yaml"] = $c' | kubectl apply -f -

  comment "Cloud controller manager and Cinder CSI: their configuration, then a restart"
  conf=$(kubectl -n kube-system get secret cloud-config -o jsonpath='{.data.cloud\.conf}' | base64 -d \
    | sed -e "s|^application-credential-id=.*|application-credential-id=${id}|" -e "s|^application-credential-secret=.*|application-credential-secret=${secret}|")
  kubectl -n kube-system get secret cloud-config -o json \
    | jq --arg c "$(base64 -w0 <<<"${conf}")" '.data["cloud.conf"] = $c' | kubectl apply -f -
  kubectl -n kube-system get deployment,daemonset -o name | grep -E 'cloud-controller|csi' | xargs kubectl -n kube-system rollout restart
  kubectl -n kube-system get deployment,daemonset -o name | grep -E 'cloud-controller|csi' | xargs -n1 kubectl -n kube-system rollout status --timeout=10m

  comment "The bootstrap instance deletes the cluster later: it needs the new credential too"
  local bootstrap
  bootstrap=$(output_raw "${SHARED}" bootstrap)
  if [[ -n "${bootstrap}" && "${bootstrap}" != null ]]; then
    copy "${next}" "${bootstrap}:/tmp/clouds.yaml"
    remote "${bootstrap}" 'sudo install -m 600 /tmp/clouds.yaml /opt/platform/clouds.yaml; rm -f /tmp/clouds.yaml'
  fi

  comment "A load balancer created with the new credential"
  # Internal: without an annotation, the cloud controller picks an external network for the
  # floating IP by itself, which the cluster may not reach (the observability plane in interface mode).
  kubectl create service loadbalancer rotation-check --tcp=80:80 --dry-run=client -o yaml \
    | kubectl annotate --local -f - service.beta.kubernetes.io/openstack-internal-load-balancer=true -o yaml \
    | kubectl apply -f -
  kubectl wait service/rotation-check --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=10m
  kubectl delete service rotation-check
  kubectl wait service/rotation-check --for=delete --timeout=10m

  comment "Revoke the old credential (${CLOUD_K8S_SHARED_CLUSTER}): the upgrade waits for it"
  wait_for_revocation "${CLOUD_K8S_SHARED_CLUSTER}"
}

# The upgrade proves the new credential only once the old one no longer authenticates. Revoking
# it needs rights the campaign does not have: wait for an administrator, up to 30 minutes.
wait_for_revocation() {  # wait_for_revocation <clouds.yaml entry>
  local attempt
  notify "Rotation done: revoke the old application credential ($1) now; the upgrade starts once it no longer authenticates (30 minutes at most)."
  for attempt in $(seq 90); do
    if ! python3 -c "import openstack, sys; openstack.connect(cloud=sys.argv[1], load_envvars=False).authorize()" "$1" >/dev/null 2>&1; then
      echo "the old credential no longer authenticates"
      return 0
    fi
    [[ $((attempt % 6)) -eq 1 ]] && echo "$(date -u +%T) waiting for the revocation of $1"
    sleep 20
  done
  echo "OLD CREDENTIAL STILL VALID"
  return 1
}

yq_credential() { python3 -c "import sys, yaml; print(yaml.safe_load(open(sys.argv[2]))['clouds']['openstack']['auth'][sys.argv[1]])" "$1" "$2"; }

# A minor upgrade by Cluster API, with the commands of the guide. The addresses must not change
# and the service must answer during and after it.
step_upgrade() {
  export KUBECONFIG=${SHARED_KUBECONFIG}
  local cluster object api service bastion vm ready=0 nodes=0 load listing
  cluster=$(cluster_name "${SHARED_KUBECONFIG}")
  object=$(tr '[:upper:].' '[:lower:]-' <<<"${UPGRADE_IMAGE}")
  api=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  service=$(shared_service_address)
  bastion=$(output_raw "${VM}" bastion)
  vm=$(first_instance_of "${VM}")
  show kubectl get nodes

  comment "The image of the new version, then the version"
  kubectl -n platform get image.openstack.k-orc.cloud -o json \
    | jq --arg name "${object}" --arg image "${UPGRADE_IMAGE}" '.items[0] | {apiVersion, kind, metadata: {name: $name, namespace: .metadata.namespace}, spec: (.spec | .import.filter.name = $image)}' \
    | kubectl apply -f -
  kubectl -n platform wait image.openstack.k-orc.cloud "${object}" --for=condition=Available --timeout=10m
  show kubectl -n platform patch cluster "${cluster}" --type=json -p "[
    {\"op\": \"replace\", \"path\": \"/spec/topology/version\", \"value\": \"${UPGRADE_VERSION}\"},
    {\"op\": \"replace\", \"path\": \"/spec/topology/variables/1/value\", \"value\": \"${object}\"}]"

  # Requests from a consumer during the upgrade: measured, kept for the results.
  rm -f "${W}/stop-load"
  load_on_shared_service "${bastion}" "${vm}" "${service}" & load=$!

  for _ in $(seq 180); do
    # The API may time out while a control plane machine is replaced: try again at the next round.
    listing=$(kubectl get nodes --no-headers --request-timeout=15s 2>/dev/null) || { sleep 20; continue; }
    nodes=$(wc -l <<<"${listing}")
    ready=$(awk -v v="${UPGRADE_VERSION}" '$2 == "Ready" && $NF == v' <<<"${listing}" | wc -l)
    echo "$(date -u +%T) nodes ${nodes}, ready at ${UPGRADE_VERSION}: ${ready}"
    if [[ ${ready} -eq $(expected_nodes || echo -1) && ${nodes} -eq ${ready} ]]; then break; fi
    sleep 20
  done
  touch "${W}/stop-load"
  wait "${load}" || true
  [[ ${ready} -eq $(expected_nodes) && ${nodes} -eq ${ready} ]]
  show kubectl get nodes

  comment "The addresses did not change, the service answers"
  [[ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" == "${api}" ]]
  kubectl get --raw /readyz >/dev/null
  [[ "$(kubectl -n traefik-internal get svc -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')" != "" ]]
  [[ "$(shared_service_address)" == "${service}" ]]
  step_accept_shared
}

expected_nodes() { local m; m=$(kubectl -n platform get machines --no-headers --request-timeout=15s) && wc -l <<<"${m}"; }

load_on_shared_service() {  # load_on_shared_service <bastion> <instance> <address>
  local ok=0 failed=0
  while [[ ! -f "${W}/stop-load" ]]; do
    if on_instance "$1" "$2" "curl -sf -o /dev/null --cacert /etc/lego/ca.pem --max-time 5 --resolve ${SHARED_NAME}:443:$3 https://${SHARED_NAME}/" 2>/dev/null; then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
    fi
    sleep 2
  done
  echo "requests during the upgrade: ${ok} ok, ${failed} failed" | tee -a "${W}/https.txt"
}

step_shared_down() {
  delete_cluster "${SHARED}" "${SHARED_KUBECONFIG}"
  destroy_stack "${SHARED}"
}
