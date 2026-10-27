#!/usr/bin/env bash
# Build the Kubernetes node image with image-builder, OpenStack builder (ADR-0002, D1).
#
# Prerequisites: the build network is applied (build-network/), build.json exists (copy of
# build.json.example), OS_CLOUD names the clouds.yaml entry of the project that will own the
# image. Needs git, make, python3 with venv, curl, unzip and OpenTofu or Terraform.
#
# Everything the build downloads (image-builder, Packer, Ansible) goes to WORK_DIR.
set -euo pipefail

IMAGE_BUILDER_VERSION="v0.1.55"
ANSIBLE_CORE_VERSION="2.18.18"
BUILD_TARGET="build-openstack-ubuntu-2404"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_dir="${WORK_DIR:-${here}/.work}"
tf="${TF:-tofu}"

: "${OS_CLOUD:?set OS_CLOUD to the clouds.yaml entry of the project that will own the image}"
[[ -f "${here}/build.json" ]] || { echo "missing ${here}/build.json (copy build.json.example)" >&2; exit 1; }

# Only the clouds.yaml entry authenticates: other OS_* variables would be mixed with it.
for var in $(compgen -e | grep '^OS_' || true); do
  [[ "${var}" == OS_CLOUD ]] || unset "${var}"
done

mkdir -p "${work_dir}"

# image-builder, pinned.
if [[ ! -d "${work_dir}/image-builder" ]]; then
  git clone --quiet --depth 1 --branch "${IMAGE_BUILDER_VERSION}" \
    https://github.com/kubernetes-sigs/image-builder.git "${work_dir}/image-builder"
fi

# Ansible in a virtual environment of the work directory, so that image-builder does not
# install it in the user's home.
if [[ ! -x "${work_dir}/venv/bin/ansible" ]]; then
  python3 -m venv "${work_dir}/venv"
  "${work_dir}/venv/bin/pip" install --quiet --disable-pip-version-check "ansible-core==${ANSIBLE_CORE_VERSION}"
fi
export PATH="${work_dir}/venv/bin:${PATH}"
export ANSIBLE_HOME="${work_dir}/ansible"
export PACKER_CONFIG_DIR="${work_dir}/packer"
export PACKER_CACHE_DIR="${work_dir}/packer-cache"

# Location of the build: network, security group and floating IP network from build-network.
"${tf}" -chdir="${here}/build-network" output -json packer_variables > "${work_dir}/network.json"

cd "${work_dir}/image-builder/images/capi"
make deps-openstack
PACKER_VAR_FILES="${here}/kubernetes.json ${here}/build.json ${work_dir}/network.json" \
  make "${BUILD_TARGET}"
