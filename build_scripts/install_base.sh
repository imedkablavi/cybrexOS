#!/bin/bash
# Legacy Arch-based installer retained only as a historical development path.
set -Eeuo pipefail

cat >&2 <<'EOF'
CybrexOS legacy installer: UNQUALIFIED AND DISABLED

This script previously contained a hardcoded /dev/sda destructive install path and
an incomplete boot configuration. It is intentionally disabled by the OS release-
engineering pass.

Use:
  build_scripts/install_cybrex.sh --help
  docs/BARE_METAL.md

No disk changes were made.
EOF

exit 2
