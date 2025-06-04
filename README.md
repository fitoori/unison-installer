⸻

Overview

install_unison_stack.sh is a one-shot, idempotent installer that turns a fresh Debian / Raspberry Pi OS system into a ready-to-use environment for OCaml + Unison development.

It handles:
	•	System tooling – git, mercurial, darcs, gcc, build-essential, curl, unzip, bubblewrap.
	•	Memory-constrained boards – auto-creates a swapfile when physical RAM < 2 GB.
	•	OPAM & OCaml – installs OPAM, creates a practical compiler switch (prefers 4.14.x; falls back to the newest available).
	•	Unison – clones, builds and installs Unison directly from source.
	•	Defensive operation – set -Eeuo pipefail, inherited ERR trap, descriptive logging, immediate abort on any error.

⸻

Prerequisites
	•	Debian 10 (Buster) or newer / Raspberry Pi OS 32- or 64-bit.
	•	Internet connection for apt and GitHub clone.
	•	Root privileges (sudo).

⸻

Quick Start

# Get the script
curl -LO https://github.com/fitoori/unison-installer/install_unison_stack.sh

# Make it executable
chmod +x install_unison_stack.sh

# Run (must be root)
sudo ./install_unison_stack.sh

Tip: add -x to the shebang for a verbose run: sudo bash -x ./install_unison_stack.sh.

When it finishes, verify:

unison -version       # should print the freshly-built Unison version
opam --version        # confirms OPAM
opam switch show      # shows the active OCaml compiler


⸻

Script Flow
	1.	Safety gates – enables strict Bash options & error trap.
	2.	RAM check & swap – creates /swapfile (SWAP_SIZE, default 2 GiB) when total RAM < MIN_RAM_MB (default 2048 MiB).
	3.	Package install – single apt-get update + bulk install of any missing packages.
	4.	OPAM install – bootstrap via official script; idempotent.
	5.	OPAM init – creates ~/.opam if absent.
	6.	Compiler switch – picks preferred OCaml version or latest available.
	7.	Build Unison – clones to a temp dir, builds under OPAM env, installs binary + man page.
	8.	Cleanup – temp build dir removed automatically; script exits 0 on success.

⸻

Customisation

Variable	Default	Purpose
SWAP_SIZE	2G	Size of swapfile when created (supports M/G suffix).
MIN_RAM_MB	2048	Below this RAM (MiB) the script enables swap.

Override on the command line:

sudo SWAP_SIZE=1G MIN_RAM_MB=1024 ./install_unison_stack.sh


⸻

Uninstall / Roll-back

The script makes only two persistent changes:
	1.	Packages – remove via sudo apt-get purge <pkg> if desired.
	2.	Swapfile – to remove:

sudo swapoff /swapfile
sudo rm -f /swapfile
sudo sed -i '\|/swapfile none swap|d' /etc/fstab

OPAM and Unison live in the invoking user’s home and /usr/local/bin; remove manually if needed.

⸻

Troubleshooting
	•	Network errors – check DNS/proxy/firewall; rerun once fixed (idempotent).
	•	OPAM mirror issues – opam update -u afterwards usually resolves.
	•	Build failures – inspect log lines printed before the [FATAL] message.
	•	Low disk space – ensure at least 1 GiB free for swap & build artefacts.

⸻

License

MIT — see LICENSE in this repository or copy pasted below.
