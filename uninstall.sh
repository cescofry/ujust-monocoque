#!/bin/bash
# Simracing Utilities Uninstaller
# Removes convenience scripts installed by install.sh.

set -euo pipefail

BIN_DIR="$HOME/.local/bin"

echo ""
echo "=== Simracing Utilities Uninstaller ==="
echo ""

# Remove convenience scripts
SCRIPTS=(simracing-launch configure-moza configure-steam-simracing telemetry-diagnose)
for script in "${SCRIPTS[@]}"; do
    if [ -f "$BIN_DIR/$script" ]; then
        rm -f "$BIN_DIR/$script"
        echo "  Removed: $script"
    fi
done

# Remove per-game launcher aliases
for alias_script in "$BIN_DIR"/simracing-launch-*; do
    if [ -f "$alias_script" ]; then
        rm -f "$alias_script"
        echo "  Removed: $(basename "$alias_script")"
    fi
done

echo ""
echo "Convenience scripts removed."
echo "Monocoque installation is NOT affected."
echo ""
