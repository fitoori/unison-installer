# Unison Installer

`install_unison_stack.sh` is a one-shot, idempotent installer that turns a fresh Debian or Raspberry Pi OS system into a ready-to-use environment for OCaml and Unison development.

## What the script does
- Installs VCS tools: git, mercurial, darcs.
- Installs build tools: gcc, build-essential, curl, unzip, bubblewrap.
- Creates a swapfile automatically on systems with less than 2 GB RAM.
- Installs OPAM, configures a practical OCaml switch (prefers 4.14.x), and builds Unison from source.
- Uses strict Bash flags, descriptive logging, and aborts immediately on any error.

## Prerequisites
- Debian 10 (Buster) or newer, or Raspberry Pi OS (32- or 64-bit).
- Internet access for `apt` and GitHub clones.
- Root privileges (`sudo`).

⸻

Prerequisites
	•	Debian 10 (Buster) or newer / Raspberry Pi OS 32- or 64-bit.
	•	Internet connection for apt and GitHub clone.
	•	Root privileges (sudo). Running without sudo will only affect the current user and skip system-wide locations such as /usr/local/bin.

⸻

Quick Start

# Get the script
## Quick start
```bash
# Download the installer
curl -LO https://github.com/fitoori/unison-installer/install_unison_stack.sh

# Make it executable
chmod +x install_unison_stack.sh

# Run (must be root)
sudo ./install_unison_stack.sh

Running without sudo will not install dependencies or Unison system-wide; tools would remain scoped to your user and may fail when writing to /usr/local. Use sudo to ensure a complete installation.

# Skip confirmation and accept defaults
sudo ./install_unison_stack.sh -y

# Show help and available overrides
./install_unison_stack.sh --help
```

After it finishes, verify the installation:
```bash
unison -version       # should print the freshly-built Unison version
opam --version        # confirms OPAM
opam switch show      # shows the active OCaml compiler
```

## Script flow
1. Safety gates: enables strict Bash options and an error trap.
2. RAM check & swap: creates `/swapfile` when physical RAM is below `MIN_RAM_MB` (default 2048 MiB).
3. Package install: runs a single `apt-get update` then installs any missing packages.
4. OPAM install: bootstraps via the official script; idempotent.
5. OPAM init: creates `~/.opam` if absent.
6. Compiler switch: picks a preferred OCaml version or the newest available.
7. Build Unison: clones, builds, and installs Unison from source.
8. Cleanup: removes the temporary build directory and exits 0 on success.

## Customisation
Environment variables let you override defaults:

| Variable   | Default | Purpose                                                |
|------------|---------|--------------------------------------------------------|
| `SWAP_SIZE`| `2G`    | Size of swapfile (supports `M`/`G` suffix).             |
| `MIN_RAM_MB` | `2048` | RAM threshold (MiB) below which swap is enabled.       |

Example:
```bash
sudo SWAP_SIZE=1G MIN_RAM_MB=1024 ./install_unison_stack.sh
```

## Uninstall / roll-back
The script makes only two persistent changes:
1. Packages: remove them with `sudo apt-get purge <pkg>` if desired.
2. Swapfile: to remove it, run:
   ```bash
   sudo swapoff /swapfile
   sudo rm -f /swapfile
   sudo sed -i '\|/swapfile none swap|d' /etc/fstab
   ```

OPAM and Unison live in the invoking user’s home and `/usr/local/bin`; remove manually if needed.

## Troubleshooting
- Network errors: check DNS/proxy/firewall; rerun once fixed (idempotent).
- OPAM mirror issues: `opam update -u` afterwards usually resolves them.
- Build failures: inspect log lines printed before the `[FATAL]` message.
- Low disk space: ensure at least 1 GiB free for swap and build artefacts.

## License
MIT — see `LICENSE` in this repository.
