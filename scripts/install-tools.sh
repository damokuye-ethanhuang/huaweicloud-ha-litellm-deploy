#!/usr/bin/env bash
# Install (or just check) the local toolchain this repo needs.
#
#   ./scripts/install-tools.sh --check     report only; exit 1 if something is missing
#   ./scripts/install-tools.sh             install whatever is missing
#   DRY_RUN=1 ./scripts/install-tools.sh   print the commands, change nothing
#
# Binaries go to ~/.local/bin (no sudo): terraform, helm, kubectl.
# Packages go through the system manager (apt/dnf/brew, may prompt for sudo):
# jq, curl, unzip, python3.
#
# The deployment itself runs on Linux in the cloud. This script only prepares the
# machine you type commands on; on Windows run it inside WSL2, never in Git Bash.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.17.0}"
HELM_VERSION="${HELM_VERSION:-3.16.3}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.1}"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"
DRY_RUN="${DRY_RUN:-0}"
MODE="install"
[ "${1:-}" = "--check" ] && MODE="check"

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  would run: %s\n' "$*"
  else
    "$@"
  fi
}

# --- platform -----------------------------------------------------------------

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  MINGW* | MSYS* | CYGWIN*)
    die "Git Bash is not supported. Install WSL2 and run this inside Ubuntu:
       powershell -c 'wsl --install -d Ubuntu'
       then reopen Ubuntu, clone the repo there, and rerun this script."
    ;;
  *) die "unsupported platform: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  arm64 | aarch64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
fi

# --- required vs present ------------------------------------------------------

# tool -> command that prints its version
have() { command -v "$1" >/dev/null 2>&1; }

missing=()
for tool in terraform helm kubectl jq curl unzip python3 git ssh; do
  have "$tool" || missing+=("$tool")
done

if [ "$MODE" = "check" ]; then
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "toolchain complete ($(uname -s) $(uname -m))"
    exit 0
  fi
  printf 'missing: %s\n' "${missing[*]}" >&2
  printf 'install them with: ./scripts/install-tools.sh\n' >&2
  exit 1
fi

if [ "${#missing[@]}" -eq 0 ]; then
  ok "nothing to do; toolchain complete"
  exit 0
fi

log "installing for $OS/$ARCH: ${missing[*]}"
log "binaries -> $LOCAL_BIN (no sudo); packages via the system package manager"
run mkdir -p "$LOCAL_BIN"

need() { printf '%s\n' "${missing[@]}" | grep -qx "$1"; }

# --- binaries: tarballs, no root needed ---------------------------------------

install_terraform() {
  local tmp; tmp="$(mktemp -d)"
  local url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip"
  log "terraform ${TERRAFORM_VERSION}"
  run curl -fsSL -o "$tmp/terraform.zip" "$url"
  run unzip -oq "$tmp/terraform.zip" -d "$LOCAL_BIN"
  if [ "$DRY_RUN" != "1" ]; then chmod +x "$LOCAL_BIN/terraform"; fi
  rm -rf "$tmp"
}

install_helm() {
  local tmp; tmp="$(mktemp -d)"
  local url="https://get.helm.sh/helm-v${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  log "helm ${HELM_VERSION}"
  run curl -fsSL -o "$tmp/helm.tgz" "$url"
  run tar -xzf "$tmp/helm.tgz" -C "$tmp"
  run install -m 0755 "$tmp/${OS}-${ARCH}/helm" "$LOCAL_BIN/helm"
  rm -rf "$tmp"
}

install_kubectl() {
  log "kubectl ${KUBECTL_VERSION}"
  local tmp; tmp="$(mktemp -d)"
  run curl -fsSL -o "$tmp/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  run install -m 0755 "$tmp/kubectl" "$LOCAL_BIN/kubectl"
  rm -rf "$tmp"
}

need terraform && install_terraform
need helm && install_helm
need kubectl && install_kubectl

# --- packages ----------------------------------------------------------------

pkgs=()
for p in jq curl unzip python3 git openssh-client; do
  need "$p" && pkgs+=("$p")
done
# ssh is `openssh-client` on Debian and `openssh` on Fedora/macOS; only used for
# the bastion hop, so a missing one is a warning rather than a hard failure.
if printf '%s\n' "${pkgs[@]:-}" | grep -qx openssh-client && [ "$OS" = "darwin" ]; then
  pkgs=("${pkgs[@]/openssh-client/}")
fi

if [ "${#pkgs[@]}" -gt 0 ]; then
  if have apt-get; then
    log "apt: ${pkgs[*]}"
    run $SUDO apt-get update -qq
    run $SUDO apt-get install -y "${pkgs[@]}" python3-venv
  elif have dnf; then
    log "dnf: ${pkgs[*]}"
    run $SUDO dnf install -y "${pkgs[@]}"
  elif have brew; then
    log "brew: ${pkgs[*]}"
    run brew install "${pkgs[@]}"
  else
    warn "no supported package manager; install by hand: ${pkgs[*]}"
  fi
fi

# --- verify ------------------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  warn "dry run: nothing was changed"
  exit 0
fi

case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *)
    warn "$LOCAL_BIN is not on PATH; add it to your shell profile:"
    printf "  export PATH=\"%s:\$PATH\"\n" "$LOCAL_BIN" >&2
    ;;
esac

exec "$(dirname "${BASH_SOURCE[0]}")/bootstrap.sh"
