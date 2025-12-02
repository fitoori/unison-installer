#!/usr/bin/env bash
###############################################################################
#                            install_unison_stack.sh                          #
#                                    v1.2.1                                   #
###############################################################################
# Production-ready installer for:
#   • VCS tools (git, hg, darcs)
#   • gcc, build-essential, curl, unzip, bubblewrap
#   • OPAM (with a practical OCaml switch) + Unison (built from source)
#   • Automatic swap creation if RAM < 2 GB (e.g. on Raspberry Pi)
#
# Target: Debian / Raspberry Pi OS
# Fails fast: exits immediately on any error with a helpful message.
###############################################################################

set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

log()   { printf '%s [INFO]  %s\n'  "$(date +'%F %T')" "$*"; }
fatal() { printf '%s [FATAL] %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }
trap 'rc=$?; fatal "cmd: \"$BASH_COMMAND\" | line: $LINENO | exit: $rc"' ERR

usage() {
  cat <<'USAGE'
Usage: sudo ./install_unison_stack.sh [-y|--yes] [-h|--help]

Options:
  -y, --yes    Run with default parameters without prompting.
  -h, --help   Show this help message.

Environment overrides:
  SWAP_SIZE     Size of swapfile (e.g. 1G).
  MIN_RAM_MB    RAM threshold (MiB) below which swap is enabled.
USAGE
}

# Allow --help/-h before any other processing (useful when not running as root).
if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

ASSUME_YES=false
while getopts ':yh-:' opt; do
  case $opt in
    y) ASSUME_YES=true ;;
    h) usage; exit 0 ;;
    -)
      case $OPTARG in
        yes) ASSUME_YES=true ;;
        help) usage; exit 0 ;;
        *) fatal "Unknown option --$OPTARG" ;;
      esac ;;
    \?) fatal "Unknown option '-$OPTARG'" ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || fatal "Unexpected arguments: $*"

# ──────────────────────────────────────────────────────────────────────────── #
# Configuration                                                               #
# ──────────────────────────────────────────────────────────────────────────── #
MIN_RAM_MB=2048                   # swap threshold
SWAP_FILE="/swapfile"
SWAP_SIZE="2G"                    # accepts “NNM” or “NNG”

swap_size_mib() {
  [[ "$SWAP_SIZE" =~ ^([0-9]+)([GgMm])$ ]] \
    || fatal "Unsupported SWAP_SIZE format '$SWAP_SIZE'"
  local n=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]}
  [[ $unit =~ [Gg] ]] && echo $(( n * 1024 )) || echo "$n"
}

[[ $(id -u) -eq 0 ]] || fatal "Run as root (with sudo) for a system-wide install. Without root, packages and binaries would be limited to your user and may fail to write to /usr/local."

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6) \
  || fatal "Cannot determine home directory for user '$REAL_USER'."
log "Real user      : $REAL_USER"
log "User home      : $USER_HOME"

confirm_defaults() {
  log "Parameters     : SWAP_SIZE=$SWAP_SIZE | MIN_RAM_MB=$MIN_RAM_MB"
  if "$ASSUME_YES"; then
    log "Assuming yes due to -y/--yes flag."
    return
  fi

  if [[ ! -t 0 ]]; then
    fatal "Cannot prompt without a TTY. Re-run with -y to accept defaults."
  fi

  printf 'Proceed with these parameters? [y/N]: '
  local reply
  read -r reply || fatal "No input received."
  [[ $reply =~ ^[Yy]$ ]] || fatal "Aborted by user."
}
confirm_defaults

# ──────────────────────────────────────────────────────────────────────────── #
# 1. Detect total RAM                                                         #
# ──────────────────────────────────────────────────────────────────────────── #
get_total_ram_mb() { grep MemTotal /proc/meminfo | awk '{print int($2/1024)}'; }

[[ -f /proc/device-tree/model ]] && {
  DEVICE_MODEL=$(tr -d '\0' </proc/device-tree/model)
  log "Device model   : $DEVICE_MODEL"
}

RAM_MB=$(get_total_ram_mb)
log "Detected RAM   : ${RAM_MB} MB"

# ──────────────────────────────────────────────────────────────────────────── #
# 2. Create swap if needed                                                    #
# ──────────────────────────────────────────────────────────────────────────── #
if (( RAM_MB < MIN_RAM_MB )); then
  if swapon --show | grep -q "^$SWAP_FILE"; then
    log "Swap file already active: $SWAP_FILE"
  else
    log "Creating $SWAP_SIZE swap at $SWAP_FILE (RAM < ${MIN_RAM_MB} MB)"
    [[ -f "$SWAP_FILE" ]] && { swapoff "$SWAP_FILE" || true; rm -f "$SWAP_FILE"; }
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE" || \
      dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$(swap_size_mib)"
    chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE"; swapon "$SWAP_FILE"
    grep -qxF "$SWAP_FILE none swap sw 0 0" /etc/fstab || \
      echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    log "Swap enabled."
  fi
else
  log "RAM ≥ ${MIN_RAM_MB} MB – swap not required."
fi

export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────────────────────────────────── #
# Wi-Fi helper – unblock rfkill & set country automatically                   #
# ──────────────────────────────────────────────────────────────────────────── #
ensure_wifi_ok() {
  if rfkill list wifi 2>/dev/null | grep -qi 'Soft blocked: yes'; then
    log "Wi-Fi appears rfkill-blocked – attempting to fix."
    local cc
    cc=$(curl -fsSL --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -d '\r\n')
    [[ ${#cc} -ne 2 ]] && { log "Geolocation failed; defaulting country to US"; cc="US"; }
    log "Setting Wi-Fi country to $cc and unblocking radio."
    if command -v raspi-config >/dev/null 2>&1; then
      raspi-config nonint do_wifi_country "$cc" || true
    else
      sed -i.bak -e "s/^country=.*/country=$cc/" \
        /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || true
    fi
    rfkill unblock wifi || true
    log "Wi-Fi rfkill unblock attempted."
  else
    log "Wi-Fi not rfkill-blocked – nothing to do."
  fi
}
ensure_wifi_ok   # need network for apt/git

# ──────────────────────────────────────────────────────────────────────────── #
# 3. Install required packages                                                #
# ──────────────────────────────────────────────────────────────────────────── #
declare -A PKG=(
  [git]=git          [hg]=mercurial   [darcs]=darcs
  [gcc]=gcc          [make]=build-essential
  [curl]=curl        [unzip]=unzip    [bwrap]=bubblewrap
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
# 4. OPAM – non-interactive install (pseudo-TTY)                              #
# ──────────────────────────────────────────────────────────────────────────── #
if ! command -v opam &>/dev/null; then
  log "Installing OPAM…"
  sudo -u "$REAL_USER" bash -lc '
    set -e
    tmp=$(mktemp /tmp/opam-install-XXXXXX.sh)
    curl -fsSL https://opam.ocaml.org/install.sh -o "$tmp"
    chmod +x "$tmp"
    # run under a tiny pseudo-tty; feed newline to accept default /usr/local/bin
    script -qfc "yes \"\" | \"$tmp\" --tty" /dev/null
  '
else
  log "OPAM already installed."
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 5. OPAM init (user scope)                                                   #
# ──────────────────────────────────────────────────────────────────────────── #
if [[ ! -d "$USER_HOME/.opam" ]]; then
  log "Initializing OPAM for $REAL_USER…"
  sudo -u "$REAL_USER" bash -lc "opam init -y --disable-sandboxing"
else
  log "OPAM already initialised."
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 6. OPAM update                                                              #
# ──────────────────────────────────────────────────────────────────────────── #
log "Updating OPAM package index…"
sudo -u "$REAL_USER" bash -lc "eval \$(opam env) && opam update -y"

# ──────────────────────────────────────────────────────────────────────────── #
# 7. Ensure a practical OCaml switch (≥ 4.08)                                 #
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

if sudo -u "$REAL_USER" bash -lc "opam switch list --short" | grep -qx default; then
  log "OPAM switch ‘default’ already exists – selecting it."
  sudo -u "$REAL_USER" bash -lc "opam switch set default"
else
  OCAML_VER=$(get_ocaml_ver)
  [[ -z "$OCAML_VER" ]] && fatal "No suitable OCaml compiler found."
  log "Creating OPAM switch ‘default’ with $OCAML_VER…"
  sudo -u "$REAL_USER" bash -lc "opam switch create default $OCAML_VER -y"
fi

# compiler sanity
log "Verifying OCaml compiler in switch…"
sudo -u "$REAL_USER" bash -lc '
  eval $(opam env)
  command -v ocamlc >/dev/null 2>&1 || opam install -y ocaml-base-compiler dune
'

# ──────────────────────────────────────────────────────────────────────────── #
# 8. Build & install Unison from source                                       #
# ──────────────────────────────────────────────────────────────────────────── #
UNISON_BUILD_DIR=$(mktemp -d /tmp/unison-build-XXXXXX)
chown "$REAL_USER":"$REAL_USER" "$UNISON_BUILD_DIR"
cleanup() { rm -rf "$UNISON_BUILD_DIR"; }
trap cleanup EXIT

if [[ -x /usr/local/bin/unison ]]; then
  log "Unison already installed – skipping build."
else
  log "Cloning Unison…"
  sudo -u "$REAL_USER" git clone --depth=1 https://github.com/bcpierce00/unison.git "$UNISON_BUILD_DIR"

  log "Building Unison…"
  sudo -u "$REAL_USER" bash -lc "
    cd '$UNISON_BUILD_DIR' &&
    eval \$(opam env) &&
    make
  "

  [[ -x "$UNISON_BUILD_DIR/src/unison" ]] || fatal "Unison binary not found."

  log "Installing Unison binary…"
  install -m 0755 "$UNISON_BUILD_DIR/src/unison" /usr/local/bin/unison

  if [[ -f "$UNISON_BUILD_DIR/man/unison.1" ]]; then
    log "Installing Unison man page…"
    install -d -m 0755 /usr/local/share/man/man1
    install -m 0644 "$UNISON_BUILD_DIR/man/unison.1" /usr/local/share/man/man1/unison.1
  fi
fi

# ──────────────────────────────────────────────────────────────────────────── #
# 9. Final sanity check                                                       #
# ──────────────────────────────────────────────────────────────────────────── #
verify_unison() {
  if sudo -u "$REAL_USER" env PATH="/usr/local/bin:$PATH" \
       unison -version >/dev/null 2>&1; then
    local ver
    ver=$(sudo -u "$REAL_USER" env PATH="/usr/local/bin:$PATH" \
              unison -version 2>&1 | head -n1)
    log "✅ Installation successful – $ver"
  else
    fatal "Unison binary installed but not runnable from $REAL_USER’s environment."
  fi
}
verify_unison
exit 0
