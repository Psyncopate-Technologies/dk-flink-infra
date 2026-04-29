#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Installs pinned Terraform + Terragrunt binaries into tools/bin/.
# Reads pinned versions from tools/versions.env. Idempotent: skips download
# when the binary already exists at the pinned version.
#
# CI:    invoked from .github/workflows/terraform-flink.yml.
# Local: run from repo root, then `export PATH="$(pwd)/tools/bin:$PATH"`.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
mkdir -p "${BIN_DIR}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/versions.env"

case "$(uname -s)" in
  Linux*)  OS=linux  ;;
  Darwin*) OS=darwin ;;
  *) echo "[install] unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64)   ARCH=amd64 ;;
  arm64|aarch64)  ARCH=arm64 ;;
  *) echo "[install] unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

install_terraform() {
  local target="${BIN_DIR}/terraform"
  if [[ -x "${target}" ]] && "${target}" -version 2>/dev/null | grep -q "Terraform v${TERRAFORM_VERSION}"; then
    echo "[install] terraform v${TERRAFORM_VERSION} already present"
    return
  fi
  local url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip"
  local tmpdir
  tmpdir="$(mktemp -d)"
  echo "[install] downloading terraform v${TERRAFORM_VERSION} (${OS}/${ARCH})"
  curl -fsSL "${url}" -o "${tmpdir}/terraform.zip"
  unzip -q "${tmpdir}/terraform.zip" -d "${tmpdir}"
  mv "${tmpdir}/terraform" "${target}"
  chmod +x "${target}"
  rm -rf "${tmpdir}"
}

install_terragrunt() {
  local target="${BIN_DIR}/terragrunt"
  if [[ -x "${target}" ]] && "${target}" -version 2>/dev/null | grep -q "v${TERRAGRUNT_VERSION}"; then
    echo "[install] terragrunt v${TERRAGRUNT_VERSION} already present"
    return
  fi
  local url="https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_${OS}_${ARCH}"
  echo "[install] downloading terragrunt v${TERRAGRUNT_VERSION} (${OS}/${ARCH})"
  curl -fsSL "${url}" -o "${target}"
  chmod +x "${target}"
}

install_terraform
install_terragrunt

echo "[install] done — binaries in ${BIN_DIR}"
