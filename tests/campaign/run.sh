#!/usr/bin/env bash
# Test campaign of the reference architecture, from empty projects to an empty teardown.
#
#     tests/campaign/run.sh <gateway|interface> <sequence or step>...
#     tests/campaign/run.sh gateway full
#     tests/campaign/run.sh interface planes edge
#
# Configuration: tests/campaign/campaign.env (see campaign.env.example). See README.md.
# The steps are the functions step_<name> of steps/*.sh, one file per phase.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"

# The two clusters are deployed one after the other, so that the campaign fits a small test cloud.
declare -A SEQUENCES=(
  [foundation]="prep planes receiver acme edge web isolated publish"
  [shared]="k8s-shared cluster-shared tour-shared accept-shared consumer shared-down"
  [published]="k8s cluster internal tour publish accept transit hostile"
  [end]="plans teardown"
  [full]="foundation shared published end"
)

mode=${1:?usage: run.sh <gateway|interface> <sequence or step>...}; shift
[[ "${mode}" == gateway || "${mode}" == interface ]] || { echo "unknown mode ${mode}" >&2; exit 2; }

# shellcheck source=/dev/null
source "${CAMPAIGN_ENV:-${here}/campaign.env}"
# shellcheck source=lib/helpers.sh
source "${here}/lib/helpers.sh"
for file in "${here}"/steps/*.sh; do
  # shellcheck source=/dev/null
  source "${file}"
done

# Only the clouds.yaml entries named in the configuration may be used.
for variable in OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME \
  OS_AUTH_URL OS_AUTH_TYPE OS_REGION_NAME OS_INTERFACE OS_CACERT OS_CLOUD; do
  unset "${variable}"
done
export TF_IN_AUTOMATION=1

TOOL=${TOOL:-tofu}
W="${WORK:-${here}/work}/${RUN:-${mode}}"     # outputs of this campaign
mkdir -p "${W}/casts"
PUBLISHED_KUBECONFIG="${W}/published.kubeconfig"
SHARED_KUBECONFIG="${W}/shared.kubeconfig"
cd "${root}" || exit 1

# A sequence expands to its steps, possibly through other sequences.
expand() {
  local item
  for item in "$@"; do
    if [[ -n "${SEQUENCES[${item}]:-}" ]]; then
      # shellcheck disable=SC2086
      expand ${SEQUENCES[${item}]}
    else
      echo "${item}"
    fi
  done
}

# With RECORD=1, the recorder runs this script again for the step alone; its status comes back in
# a file, since asciinema does not return it.
run_step() {
  local name=$1 function="step_${1//-/_}" status
  declare -F "${function}" >/dev/null || { echo "unknown step ${name}" >&2; return 2; }
  if [[ "${RECORD:-0}" == 1 && -z "${CAMPAIGN_INNER:-}" ]]; then
    CAMPAIGN_INNER=1 asciinema rec -q --overwrite --cols "${CAST_COLS:-130}" --rows "${CAST_ROWS:-40}" \
      --title "${name}" -c "bash '${here}/run.sh' ${mode} ${name}" \
      "${W}/casts/$(date -u +%m%d-%H%M)-${mode}-${name}.cast"
    status=$(cat "${W}/.status" 2>/dev/null || echo 1)
  else
    heading "${name}"
    # errexit in a subshell: any command that fails stops the step. It only applies outside a
    # condition, hence the plain call here and in the loop below.
    ( set -e; "${function}" ); status=$?
    [[ -n "${CAMPAIGN_INNER:-}" ]] && echo "${status}" > "${W}/.status"
  fi
  return "${status}"
}

for name in $(expand "$@"); do
  run_step "${name}"; status=$?
  [[ ${status} -eq 0 ]] || { echo "campaign stopped at step ${name}"; exit 1; }
done
