#!/bin/bash
# Simracing Utilities Installer
# Installs convenience scripts for the monocoque sim racing telemetry stack.

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo ""
echo "=== Simracing Utilities Installer ==="
echo ""

# Check monocoque is installed
MONOCOQUE_FOUND=false
if command -v start-monocoque &>/dev/null; then
    MONOCOQUE_FOUND=true
elif distrobox list 2>/dev/null | grep -q simracing; then
    MONOCOQUE_FOUND=true
fi

if [ "$MONOCOQUE_FOUND" = false ]; then
    log_error "Monocoque is not installed."
    echo ""
    echo "  Install monocoque first:"
    echo "    https://github.com/Spacefreak18/monocoque"
    echo ""
    echo "  For immutable distros (Bazzite, Silverblue), use the distrobox installer:"
    echo "    bash tools/distro/distrobox/install-distrobox.sh"
    echo ""
    exit 1
fi

# Check PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    log_error "$BIN_DIR is not in your PATH."
    log_info "Add this to your shell config:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    exit 1
fi

# Install scripts
mkdir -p "$BIN_DIR"
SCRIPTS=(simracing-launch configure-moza configure-steam-simracing telemetry-diagnose)

for script in "${SCRIPTS[@]}"; do
    if [ -f "$SCRIPT_DIR/scripts/$script" ]; then
        cp "$SCRIPT_DIR/scripts/$script" "$BIN_DIR/$script"
        chmod +x "$BIN_DIR/$script"
    else
        log_warn "Script not found: scripts/$script"
    fi
done

log_success "Installation complete!"
echo ""
echo "  Installed:"
echo "    simracing-launch          - Unified game launcher (manages simd + monocoque + bridge lifecycle)"
echo "    configure-moza            - Auto-detect Moza wheel base and update monocoque config"
echo "    configure-steam-simracing - Configure Steam launch options for sim racing games"
echo "    telemetry-diagnose        - Runtime diagnostic tool for troubleshooting"
echo ""
echo "  Quick start:"
echo "    1. Connect your Moza wheel base and run: configure-moza"
echo "    2. Close Steam and run: configure-steam-simracing"
echo "    3. Launch any configured sim from Steam"
echo ""
