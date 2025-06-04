#!/usr/bin/env bash

###############################################################################
#                            install_unison_stack.sh                          #
#                                      v1.1.1                                 #
###############################################################################
# Production-ready installer for:
#   • VCS tools (git, hg, darcs)
#   • gcc, build-essential, curl, unzip, bubblewrap
#   • OPAM (with a practical OCaml switch) + Unison (built from source)
#   • Automatic swap creation if RAM < 2 GB (e.g. on Raspberry Pi)
#
# Target: Debian / Raspberry Pi OS
# Fails fast: exits immediately on any error with a helpful message.

set -Eeuo pipefail
shopt -s inherit_errexit             # make ERR trap propagate into subshells
IFS=$'\n\t'

log()   { printf '%s [INFO]  %s\n'  "$(date +'%F %T')" "$*"; }
fatal() { printf '%s [FATAL] %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }
trap 'rc=$?; fatal "cmd: \"$BASH_COMMAND\" | line: $LINENO | exit: $rc"' ERR

# ──────────────────────────────────────────────────────────────────────────── #
# Configuration
# ──────────────────────────────────────────────────────────────────────────── #
MIN_RAM_MB=2048                 # skip swap if we have this much RAM
SWAP_FILE="/swapfile"
SWAP_SIZE="2G"                  # accepts “NNM” or “NNG”

# Convert $SWAP_SIZE → MiB for dd fallback
swap_size_mib() {
  [[ "$SWAP_SIZE" =~ ^([0-9]+)([GgMm])$ ]] \
    || fatal "Unsupported SWAP_SIZE format '$SWAP_SIZE'"

  local n=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]}
  [[ $unit =~ [Gg] ]] && echo $(( n * 1024 )) || echo "$n"
}

# Must run as root
[[ $(id -u) -eq 0 ]] || fatal "Run as root (with sudo)."

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6) \
  || fatal "Cannot determine home directory for user '$REAL_USER'."
log "Real user      : $REAL_USER"
log "User home      : $USER_HOME"

# ──────────────────────────────────────────────────────────────────────────── #
# 1. Detect total RAM
# ──────────────────────────────────────────────────────────────────────────── #
get_total_ram_mb() {
  grep MemTotal /proc/meminfo | awk '{print int($2/1024)}'
}

if [[ -f /proc/device-tree/model ]]; then
  DEVICE_MODEL=$(tr -d '\0' </proc/device-tree/model)
  log "Device model   : $DEVICE_MODEL"
fi

RAM_MB=$(get_total_ram_mb)
log "Detected RAM   : ${RAM_MB} MB"

# ──────────────────────────────────────────────────────────────────────────── #
# 2. Create swap if needed
# ──────────────────────────────────────────────────────────────────────────── #
if (( RAM_MB < MIN_RAM_MB )); then
  if swapon --show | grep -q "^$SWAP_FILE"; then
    log "Swap file already active: $SWAP_FILE"
  else
    log "Creating $SWAP_SIZE swap at $SWAP_FILE (RAM < ${MIN_RAM_MB} MB)"
    [[ -f "$SWAP_FILE" ]] && { swapoff "$SWAP_FILE" || true; rm -f "$SWAP_FILE"; }

    fallocate -l "$SWAP_SIZE" "$SWAP_FILE" || \
      dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$(swap_size_mib)"

    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    grep -qxF "$SWAP_FILE none swap sw 0 0" /etc/fstab || \
      echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    log "Swap enabled."
  fi
else
  log "RAM ≥ ${MIN_RAM_MB} MB – swap not required."
fi

export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────────────────────────────────── #
# 3. Install required packages (single apt transaction)
# ──────────────────────────────────────────────────────────────────────────── #
declare -A PKG=(
  [git]=git
  [hg]=mercurial
  [darcs]=darcs
  [gcc]=gcc
  [make]=build-essential
  [curl]=curl
  [unzip]=unzip
  [bwrap]=bubblewrap
)

missing_pkgs=()
for cmd in "${!PKG[@]}"; do
  if command -v "$cmd" &>/dev/null; then
    log "‘$cmd’ already installed."
  else
    log "‘$cmd’ missing – will install ‘${PKG[$cmd]}’."
    missing_pkgs+=("${PKG[$cmd]}")
  fi
done

if ((${#missing_pkgs[@]})); then
  log "Running apt-get update & install: ${missing_pkgs[*]}"
  apt-get update -qq
  apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 4. OPAM – install if absent
# ──────────────────────────────────────────────────────────────────────────── #
if ! command -v opam &>/dev/null; then
  log "Installing OPAM…"
  sudo -u "$REAL_USER" bash -lc "curl -fsSL https://opam.ocaml.org/install.sh | sh"
else
  log "OPAM already installed."
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 5. OPAM init (user scope)
# ──────────────────────────────────────────────────────────────────────────── #
if [[ ! -d "$USER_HOME/.opam" ]]; then
  log "Initializing OPAM for $REAL_USER…"
  sudo -u "$REAL_USER" bash -lc "opam init -y"
else
  log "OPAM already initialised."
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 6. OPAM update
# ──────────────────────────────────────────────────────────────────────────── #
log "Updating OPAM package index…"
sudo -u "$REAL_USER" bash -lc "eval \$(opam env) && opam update -y"

# ──────────────────────────────────────────────────────────────────────────── #
# 7. Ensure a practical OCaml switch (≥ 4.08)
# ──────────────────────────────────────────────────────────────────────────── #
PREFERRED_VERSIONS=(
  "ocaml-base-compiler.4.14.2"
  "ocaml-base-compiler.4.14.1"
  "ocaml-base-compiler.4.12.1"
)

get_ocaml_ver() {
  local available
  available=$(sudo -u "$REAL_USER" bash -lc \
    "opam switch list-available --short" 2>/dev/null |
    awk '/^ocaml-base-compiler\.[0-9]+\.[0-9]+\.[0-9]+$/')
  for v in "${PREFERRED_VERSIONS[@]}"; do
    grep -qx "$v" <<<"$available" && { echo "$v"; return; }
  done
  echo "$available" | sort -V | tail -n1
}

# Does a switch called “default” already exist?
if sudo -u "$REAL_USER" bash -lc "opam switch list --short" | grep -qx default; then
  log "OPAM switch 'default' already exists – selecting it."
  sudo -u "$REAL_USER" bash -lc "opam switch set default"
else
  OCAML_VER=$(get_ocaml_ver)
  [[ -z "$OCAML_VER" ]] && fatal "No suitable OCaml compiler found."
  log "Creating default OPAM switch with $OCAML_VER…"
  sudo -u "$REAL_USER" bash -lc "opam switch create default $OCAML_VER -y"
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 8. Build & install Unison from source
# ──────────────────────────────────────────────────────────────────────────── #
# Create temp dir as the real user so ownership is correct
UNISON_BUILD_DIR=$(sudo -u "$REAL_USER" mktemp -d /tmp/unison-build-XXXXXX)
cleanup() { rm -rf "$UNISON_BUILD_DIR"; }
trap cleanup EXIT

if [[ -x "/usr/local/bin/unison" ]]; then
  log "Unison already installed – skipping build."
else
  log "Cloning Unison…"
  git clone --depth=1 https://github.com/bcpierce00/unison.git "$UNISON_BUILD_DIR"

  log "Building Unison (this may take a minute)…"
  sudo -u "$REAL_USER" bash -lc "
    cd '$UNISON_BUILD_DIR' &&
    eval \$(opam env) &&
    make
  "

  [[ -x "$UNISON_BUILD_DIR/src/unison" ]] \
    || fatal "Unison build failed – binary not found."

  log "Installing Unison binary + man page…"
  install -m 0755 "$UNISON_BUILD_DIR/src/unison" /usr/local/bin/unison
  if [[ -f "$UNISON_BUILD_DIR/man/unison.1" ]]; then
    install -m 0644 "$UNISON_BUILD_DIR/man/unison.1" \
      /usr/local/share/man/man1/unison.1
  fi
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 9. Final sanity check: does Unison actually run?
# ──────────────────────────────────────────────────────────────────────────── #
verify_unison() {
  if unison --version >/dev/null 2>&1; then
    # Capture version string for the log
    local ver
    ver=$(unison --version 2>&1 | head -n1)
    log "✅ Installation successful – $ver"
  else
    fatal "Unison binary not found or failed to execute."
  fi
}

verify_unison
exit 0
