#!/usr/bin/env bash
# Provisiona VM Multipass e sobe FluxoDeCaixa com make start.
set -euo pipefail

VM_NAME="${VM_NAME:-minha-vm}"
VM_MEMORY="${VM_MEMORY:-18G}"
VM_DISK="${VM_DISK:-120G}"
VM_CPUS="${VM_CPUS:-8}"
FLUXO_REPO="${FLUXO_REPO:-https://github.com/dan5e3s6ares/FluxoDeCaixa.git}"
FLUXO_DIR="${FLUXO_DIR:-FluxoDeCaixa}"

log() {
  echo ">> $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: '$1' not found in PATH" >&2
    exit 1
  fi
}

require_cmd multipass

log "Removendo todas as instâncias Multipass..."
multipass delete --all --purge

log "Criando VM '${VM_NAME}' (${VM_CPUS} CPUs, ${VM_MEMORY} RAM, ${VM_DISK} disco)..."
multipass launch --name "${VM_NAME}" --memory "${VM_MEMORY}" --disk "${VM_DISK}" --cpus "${VM_CPUS}"

log "Aguardando cloud-init na VM..."
multipass exec "${VM_NAME}" -- cloud-init status --wait

log "Clonando repositório e executando make start dentro da VM..."
multipass exec "${VM_NAME}" -- bash -s -- "${FLUXO_REPO}" "${FLUXO_DIR}" <<'REMOTE'
set -euo pipefail
FLUXO_REPO="$1"
FLUXO_DIR="$2"
HOME_DIR="${HOME}"

if [[ -d "${HOME_DIR}/${FLUXO_DIR}/.git" ]]; then
  echo ">> Repositório já existe; atualizando..."
  git -C "${HOME_DIR}/${FLUXO_DIR}" pull --ff-only
else
  git clone "${FLUXO_REPO}" "${HOME_DIR}/${FLUXO_DIR}"
fi

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq make git

cd "${HOME_DIR}/${FLUXO_DIR}"
sudo make start
REMOTE

log "Stack iniciada na VM '${VM_NAME}'."
log "Acesso interativo: make vm-shell   (ou: multipass shell ${VM_NAME})"

if [[ "${VM_SHELL:-0}" == "1" ]] && [[ -t 0 ]]; then
  exec multipass shell "${VM_NAME}"
fi
