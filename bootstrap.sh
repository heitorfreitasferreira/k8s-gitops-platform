#!/usr/bin/env bash
# Bootstrap da plataforma Talos. O modulo platform cria os Secrets no cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="${ROOT}/terraform/platform"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/talos-kubeconfig}"
export KUBECONFIG

command -v terraform >/dev/null || { echo "terraform ausente" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl ausente" >&2; exit 1; }
[[ -f "${KUBECONFIG}" ]] || {
  echo "kubeconfig nao encontrado: ${KUBECONFIG}" >&2
  echo "Gere-o pelo modulo terraform/infra antes do bootstrap." >&2
  exit 1
}

terraform -chdir="${PLATFORM}" init
terraform -chdir="${PLATFORM}" apply
