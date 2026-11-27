#!/usr/bin/env bash
# Write the scripts and manifests of a Kubernetes stack (its scripts and manifests outputs) into a
# directory, the layout update-cluster.sh runs from (ADR-0017, D3):
#
#     scripts/cluster-files.sh stacks/tenants/kubernetes <directory> [--tool tofu|terraform]
#     KUBECONFIG=<cluster>.kubeconfig <directory>/update-cluster.sh
#
# Run it again after each apply of the stack: the directory then holds the new version. With
# certificates, the manifests hold the key of the DNS provider: the directory is readable by its
# owner only. To update the cluster's credential, put the new clouds.yaml (entry "openstack") and,
# for a private certificate authority, cacert.pem in the directory before running update-cluster.sh.
# Needs jq.
set -euo pipefail

tool=tofu
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) tool="$2"; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ ${#args[@]} -eq 2 ]] || { echo "usage: $0 <Kubernetes stack> <directory> [--tool tofu|terraform]" >&2; exit 2; }
stack=${args[0]} dir=${args[1]}

umask 077
mkdir -p "$dir/manifests"
scripts=$("$tool" -chdir="$stack" output -json scripts)
manifests=$("$tool" -chdir="$stack" output -json manifests)
for name in $(jq -r 'keys[]' <<<"$scripts"); do
  jq -j --arg n "$name" '.[$n]' <<<"$scripts" > "$dir/$name"
  chmod 700 "$dir/$name"
done
for name in $(jq -r 'keys[]' <<<"$manifests"); do
  jq -j --arg n "$name" '.[$n]' <<<"$manifests" > "$dir/manifests/$name"
done
"$tool" -chdir="$stack" output -raw revision > "$dir/revision"
echo "Written in $dir: $(jq -r 'keys | join(", ")' <<<"$scripts"), manifests/."
