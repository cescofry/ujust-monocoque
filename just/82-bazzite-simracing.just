# vim: set ft=make :

# Install monocoque sim racing telemetry stack (Moza RPM LEDs)
[group("Gaming")]
setup-monocoque:
    #!/usr/bin/env bash
    set -euo pipefail
    CONTAINER="simracing"
    INSTALL_DIR="$HOME/.local/share/simracing"
    SCRIPTS_DIR="$HOME/.local/bin"

    echo "=== Monocoque Setup (Moza RPM Telemetry) ==="
    echo ""

    # Ensure ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo "NOTE: ~/.local/bin is not in your PATH."
        echo "Add it to your shell profile if commands are not found after install."
        echo ""
    fi

    # Ensure dialout group is available and user is a member
    if ! grep -q '^dialout:' /etc/group 2>/dev/null; then
        if grep -q '^dialout:' /usr/lib/group 2>/dev/null; then
            echo "Adding dialout group to /etc/group (Fedora Atomic/Bazzite fix)..."
            grep -E '^dialout:' /usr/lib/group | sudo tee -a /etc/group >/dev/null
        else
            echo "Creating dialout group..."
            sudo groupadd dialout
        fi
    fi
    if ! groups | grep -qw dialout; then
        echo "Adding $USER to the dialout group for serial device access..."
        sudo usermod -aG dialout "$USER"
        echo "NOTE: You will need to REBOOT after setup completes for serial access to work."
        echo ""
    fi

    # Prevent ModemManager from grabbing Moza serial devices
    UDEV_RULE="/etc/udev/rules.d/99-moza-serial.rules"
    if [ ! -f "$UDEV_RULE" ]; then
        echo "Installing udev rule to prevent ModemManager from grabbing Moza devices..."
        echo 'ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="346e", ENV{ID_MM_DEVICE_IGNORE}="1"' | sudo tee "$UDEV_RULE" >/dev/null
        sudo udevadm control --reload-rules
        sudo udevadm trigger
    fi

    # Create the Arch Linux container if it doesn't exist
    if ! distrobox list 2>/dev/null | grep -q "$CONTAINER"; then
        echo "Creating Arch Linux container '$CONTAINER'..."
        distrobox create \
            --image docker.io/library/archlinux:latest \
            --name "$CONTAINER" \
            --pre-init-hooks "sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf && pacman -Sy --noconfirm archlinux-keyring && pacman-key --init && pacman-key --populate archlinux && sed -i 's/^SigLevel.*/SigLevel = Required DatabaseOptional/' /etc/pacman.conf"
    else
        echo "Container '$CONTAINER' already exists, skipping creation."
    fi

    # Install AUR helper and packages inside the container
    distrobox enter "$CONTAINER" -- bash -c '
        set -euo pipefail

        # Install build dependencies
        echo "Installing build dependencies..."
        sudo pacman -Syu --needed --noconfirm base-devel git mingw-w64-gcc

        # Install yay (AUR helper) if not present
        if ! command -v yay &>/dev/null; then
            echo "Installing yay AUR helper..."
            TMPDIR=$(mktemp -d)
            git clone https://aur.archlinux.org/yay-bin.git "$TMPDIR/yay-bin"
            cd "$TMPDIR/yay-bin"
            makepkg -si --noconfirm
            cd /
            rm -rf "$TMPDIR"
        fi

        # Install AUR packages sequentially (simd depends on simapi, monocoque depends on both)
        echo "Installing AUR packages..."
        yay -S --needed --noconfirm simapi-git
        yay -S --needed --noconfirm simd-git
        yay -S --needed --noconfirm monocoque-git

        # Build simshmbridge manually (not on AUR)
        INSTALL_DIR="$HOME/.local/share/simracing"
        mkdir -p "$INSTALL_DIR"
        cd "$INSTALL_DIR"
        if [ ! -d "simshmbridge" ]; then
            echo "Cloning simshmbridge..."
            git clone --recurse-submodules "https://github.com/Spacefreak18/simshmbridge.git"
        else
            echo "simshmbridge already cloned, pulling latest..."
            cd simshmbridge && git pull && git submodule update --init --recursive && cd ..
        fi
        echo "Building simshmbridge..."
        cd "$INSTALL_DIR/simshmbridge"
        git submodule update --init --recursive
        make clean 2>/dev/null || true
        make -j$(nproc)

        echo ""
        echo "All components built successfully inside container."
    '

    # Install launcher scripts to ~/.local/bin
    mkdir -p "$SCRIPTS_DIR"

    cat > "$SCRIPTS_DIR/start-simd" << 'SCRIPT'
    #!/usr/bin/env bash
    exec distrobox enter simracing -- simd "$@"
    SCRIPT
    chmod +x "$SCRIPTS_DIR/start-simd"

    cat > "$SCRIPTS_DIR/start-monocoque" << 'SCRIPT'
    #!/usr/bin/env bash
    exec distrobox enter simracing -- monocoque play "$@"
    SCRIPT
    chmod +x "$SCRIPTS_DIR/start-monocoque"

    cat > "$SCRIPTS_DIR/test-monocoque" << 'SCRIPT'
    #!/usr/bin/env bash
    exec distrobox enter simracing -- monocoque test -vv "$@"
    SCRIPT
    chmod +x "$SCRIPTS_DIR/test-monocoque"

    cat > "$SCRIPTS_DIR/simracing-launch" << 'SCRIPT'
    #!/usr/bin/env bash
    # Unified sim racing launcher — starts telemetry stack and runs the game.
    # Usage: simracing-launch [bridge_exe|none] %command%
    #   bridge_exe: path to simshmbridge .exe, or "none" for games with native shm/UDP
    set -euo pipefail

    BRIDGE="${1:-none}"; shift

    cleanup() {
        echo "[simracing] Game exited, stopping telemetry stack..."
        [ -n "${SIMD_PID:-}" ] && kill "$SIMD_PID" 2>/dev/null || true
        [ -n "${MONO_PID:-}" ] && kill "$MONO_PID" 2>/dev/null || true
    }
    trap cleanup EXIT

    # Start simd if not already running
    SIMD_PID=""
    if ! pgrep -f "simd" >/dev/null 2>&1; then
        echo "[simracing] Starting simd..."
        distrobox enter simracing -- simd &
        SIMD_PID=$!
        sleep 2
    else
        echo "[simracing] simd already running."
    fi

    # Start monocoque if not already running
    MONO_PID=""
    if ! pgrep -f "monocoque.*play" >/dev/null 2>&1; then
        echo "[simracing] Starting monocoque..."
        distrobox enter simracing -- monocoque play &
        MONO_PID=$!
    else
        echo "[simracing] monocoque already running."
    fi

    # Launch the game (with or without bridge)
    if [ "$BRIDGE" != "none" ]; then
        SIMD_BRIDGE_EXE="$BRIDGE" "$@"
    else
        "$@"
    fi
    SCRIPT
    chmod +x "$SCRIPTS_DIR/simracing-launch"

    cat > "$SCRIPTS_DIR/configure-moza" << 'SCRIPT'
    #!/usr/bin/env bash
    # Detects the Moza wheel base serial device and configures monocoque.
    set -euo pipefail

    CONFIG="$HOME/.config/monocoque/monocoque.config"

    if [ ! -f "$CONFIG" ]; then
        echo "ERROR: monocoque config not found at $CONFIG"
        echo "Run 'ujust setup-monocoque' first."
        exit 1
    fi

    echo "Scanning for Moza wheel base..."
    MOZA_TTY=""
    for dev in /dev/serial/by-id/*; do
        [ -e "$dev" ] || continue
        name=$(basename "$dev")
        if [[ "$name" =~ [Mm][Oo][Zz][Aa]|[Gg][Uu][Dd][Ss][Ee][Nn] ]] && [[ "$name" =~ [Bb][Aa][Ss][Ee] ]]; then
            MOZA_TTY=$(readlink -f "$dev")
            break
        fi
    done

    if [ -z "$MOZA_TTY" ]; then
        echo ""
        echo "No Moza wheel base found."
        echo ""
        echo "Make sure your wheel base is:"
        echo "  1. Plugged in via USB"
        echo "  2. Powered on"
        echo "  3. You are in the 'dialout' group (check with: groups | grep dialout)"
        echo ""
        echo "Then run this script again: configure-moza"
        exit 1
    fi

    echo "Found: $MOZA_TTY"

    # Check if already configured with this device
    if grep -q "$MOZA_TTY" "$CONFIG" 2>/dev/null; then
        echo "monocoque config already points to this device. Nothing to do."
        exit 0
    fi

    # Replace placeholder or existing device path
    if grep -q "CHANGE_ME_TO_MOZA_DEVICE" "$CONFIG"; then
        sed -i "s|CHANGE_ME_TO_MOZA_DEVICE|$MOZA_TTY|" "$CONFIG"
    elif grep -q 'devpath.*=.*"/dev/' "$CONFIG"; then
        sed -i "s|devpath.*=.*\"/dev/[^\"]*\"|devpath      = \"$MOZA_TTY\"|" "$CONFIG"
    else
        echo "WARNING: Could not find devpath line to update in $CONFIG"
        echo "Please manually set devpath to: $MOZA_TTY"
        exit 1
    fi

    echo "Updated $CONFIG with device: $MOZA_TTY"
    echo ""
    echo "You can verify with: test-monocoque"
    SCRIPT
    chmod +x "$SCRIPTS_DIR/configure-moza"

    cat > "$SCRIPTS_DIR/configure-steam-simracing" << 'SCRIPT'
    #!/usr/bin/env bash
    # Detects installed sim racing games in Steam and sets up launch options
    # to use the simracing-launch wrapper (simd + monocoque + bridge).
    #
    # IMPORTANT: Steam must be closed before running this script.
    set -euo pipefail

    INSTALL_DIR="$HOME/.local/share/simracing"
    BRIDGE_DIR="$INSTALL_DIR/simshmbridge/assets"

    # Known sim racing games: AppID -> "Name|bridge_exe_or_none"
    declare -A GAMES=(
        [244210]="Assetto Corsa|$BRIDGE_DIR/acbridge.exe"
        [805550]="Assetto Corsa Competizione|$BRIDGE_DIR/acbridge.exe"
        [1066890]="Automobilista 2|$BRIDGE_DIR/pcars2bridge.exe"
        [378860]="Project Cars 2|$BRIDGE_DIR/pcars2bridge.exe"
        [365960]="rFactor 2|$BRIDGE_DIR/rf2bridge.exe"
        [2069810]="Le Mans Ultimate|$BRIDGE_DIR/rf2bridge.exe"
        [227300]="Euro Truck Simulator 2|none"
        [270880]="American Truck Simulator|none"
        [284160]="BeamNG.drive|none"
    )

    # Check Steam is not running
    if pgrep -x steam >/dev/null 2>&1; then
        echo "ERROR: Steam is currently running."
        echo "Please close Steam completely and run this script again."
        echo "(Steam overwrites localconfig.vdf on exit, which would undo our changes.)"
        exit 1
    fi

    # Find Steam userdata directories
    STEAM_ROOT="$HOME/.steam/steam"
    if [ ! -d "$STEAM_ROOT/userdata" ]; then
        STEAM_ROOT="$HOME/.local/share/Steam"
    fi
    if [ ! -d "$STEAM_ROOT/userdata" ]; then
        echo "ERROR: Could not find Steam userdata directory."
        echo "Looked in ~/.steam/steam/userdata and ~/.local/share/Steam/userdata"
        exit 1
    fi

    # Find installed games by checking appmanifest files in library folders
    INSTALLED_APPIDS=()
    LIBFOLDERS="$STEAM_ROOT/steamapps/libraryfolders.vdf"
    if [ -f "$LIBFOLDERS" ]; then
        LIB_PATHS=$(grep '"path"' "$LIBFOLDERS" | sed 's/.*"\([^"]*\)"/\1/' || true)
    else
        LIB_PATHS="$STEAM_ROOT"
    fi

    for LIB in $LIB_PATHS; do
        STEAMAPPS="$LIB/steamapps"
        if [ -d "$STEAMAPPS" ]; then
            for MANIFEST in "$STEAMAPPS"/appmanifest_*.acf; do
                [ -f "$MANIFEST" ] || continue
                APPID=$(basename "$MANIFEST" | sed 's/appmanifest_\(.*\)\.acf/\1/')
                if [ -n "${GAMES[$APPID]+x}" ]; then
                    INSTALLED_APPIDS+=("$APPID")
                fi
            done
        fi
    done

    if [ ${#INSTALLED_APPIDS[@]} -eq 0 ]; then
        echo "No supported sim racing games found in Steam library."
        echo "Supported games:"
        for APPID in "${!GAMES[@]}"; do
            IFS='|' read -r NAME _ <<< "${GAMES[$APPID]}"
            echo "  - $NAME"
        done
        exit 0
    fi

    # Show found games and let user select which to configure
    echo "Found installed sim racing games:"
    echo ""
    for i in "${!INSTALLED_APPIDS[@]}"; do
        APPID="${INSTALLED_APPIDS[$i]}"
        IFS='|' read -r NAME BRIDGE <<< "${GAMES[$APPID]}"
        BRIDGE_LABEL="$BRIDGE"
        [ "$BRIDGE" = "none" ] && BRIDGE_LABEL="no bridge needed"
        echo "  $((i+1)). $NAME ($BRIDGE_LABEL)"
    done
    echo ""
    echo "  A. Configure all"
    echo "  Q. Quit"
    echo ""
    read -rp "Select games to configure (e.g. 1,3 or A for all): " SELECTION

    SELECTED_APPIDS=()
    if [[ "$SELECTION" =~ ^[Aa]$ ]]; then
        SELECTED_APPIDS=("${INSTALLED_APPIDS[@]}")
    elif [[ "$SELECTION" =~ ^[Qq]$ ]]; then
        echo "No changes made."
        exit 0
    else
        IFS=',' read -ra INDICES <<< "$SELECTION"
        for IDX in "${INDICES[@]}"; do
            IDX=$(echo "$IDX" | tr -d ' ')
            if [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$IDX" -ge 1 ] && [ "$IDX" -le ${#INSTALLED_APPIDS[@]} ]; then
                SELECTED_APPIDS+=("${INSTALLED_APPIDS[$((IDX-1))]}")
            fi
        done
    fi

    if [ ${#SELECTED_APPIDS[@]} -eq 0 ]; then
        echo "No valid selection. No changes made."
        exit 0
    fi

    # Find and update localconfig.vdf for each Steam user
    CHANGES_MADE=0
    for USERDIR in "$STEAM_ROOT"/userdata/*/config; do
        LOCALCONFIG="$USERDIR/localconfig.vdf"
        [ -f "$LOCALCONFIG" ] || continue

        # Backup before modifying
        cp "$LOCALCONFIG" "$LOCALCONFIG.bak.$(date +%Y%m%d%H%M%S)"

        for APPID in "${SELECTED_APPIDS[@]}"; do
            IFS='|' read -r NAME BRIDGE <<< "${GAMES[$APPID]}"
            LAUNCH_OPT="simracing-launch $BRIDGE %command%"

            # Use python3 to safely modify VDF
            python3 - "$LOCALCONFIG" "$APPID" "$LAUNCH_OPT" << 'PYEOF'
    import sys, re

    config_path, appid, launch_opt = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(config_path, 'r') as f:
        content = f.read()

    app_pattern = r'("' + appid + r'"[\s]*\{[^}]*)\}'
    match = re.search(app_pattern, content)

    if match:
        block = match.group(1)
        lo_pattern = r'"LaunchOptions"\s*"[^"]*"'
        replacement = '"LaunchOptions"\t\t"' + launch_opt + '"'
        if re.search(lo_pattern, block):
            new_block = re.sub(lo_pattern, replacement, block)
        else:
            new_block = block + '\n\t\t\t\t\t\t\t' + replacement
        content = content.replace(block, new_block)
        with open(config_path, 'w') as f:
            f.write(content)
        print("  Configured: " + appid)
    else:
        print("  App " + appid + " not found in localconfig.vdf (may not have been launched yet)")
    PYEOF
            CHANGES_MADE=1
        done
    done

    if [ "$CHANGES_MADE" -eq 1 ]; then
        echo ""
        echo "Steam launch options configured!"
        echo "A backup was saved as localconfig.vdf.bak.*"
        echo ""
        echo "You can now launch these games from Steam — simd, monocoque, and the"
        echo "bridge will start automatically when the game launches."
    else
        echo "No localconfig.vdf found. Launch each game at least once from Steam, then re-run."
    fi
    SCRIPT
    chmod +x "$SCRIPTS_DIR/configure-steam-simracing"

    # Setup monocoque config
    mkdir -p "$HOME/.config/monocoque"
    if [ ! -f "$HOME/.config/monocoque/monocoque.config" ]; then
        cat > "$HOME/.config/monocoque/monocoque.config" << 'MONOCONF'
    configs = (
        {
            sim = "default";
            car = "default";
            devices = (
            {
                device       = "Serial";
                type         = "Wheel";
                subtype      = "MozaNew";
                devpath      = "CHANGE_ME_TO_MOZA_DEVICE";
                baud         = 115200;
            });
        }
    );
    MONOCONF
        echo "Created monocoque config at ~/.config/monocoque/monocoque.config"
    fi

    # Auto-detect Moza device if wheel is connected
    MOZA_TTY=""
    for dev in /dev/serial/by-id/*; do
        [ -e "$dev" ] || continue
        name=$(basename "$dev")
        if [[ "$name" =~ [Mm][Oo][Zz][Aa]|[Gg][Uu][Dd][Ss][Ee][Nn] ]] && [[ "$name" =~ [Bb][Aa][Ss][Ee] ]]; then
            MOZA_TTY=$(readlink -f "$dev")
            break
        fi
    done
    if [ -n "$MOZA_TTY" ]; then
        sed -i "s|CHANGE_ME_TO_MOZA_DEVICE|$MOZA_TTY|" \
            "$HOME/.config/monocoque/monocoque.config"
        echo "Auto-detected Moza base: $MOZA_TTY"
    else
        echo ""
        echo "WARNING: No Moza wheel base detected."
        echo "  Connect and power on your wheel base, then run:"
        echo "    configure-moza"
        echo ""
    fi

    echo ""
    echo "============================================"
    echo "  Monocoque installed!"
    echo "============================================"
    echo ""
    echo "Monocoque drives your Moza RPM LEDs from live sim telemetry."
    echo ""
    echo "Installed:"
    echo "  AUR pkgs:      simapi-git, simd-git, monocoque-git (in container)"
    echo "  Bridge:         ~/.local/share/simracing/simshmbridge/"
    echo "  Config:         ~/.config/monocoque/"
    echo "  Launchers:      ~/.local/bin/start-simd, start-monocoque, test-monocoque"
    echo "  Unified launch: ~/.local/bin/simracing-launch"
    echo "  Config tools:   ~/.local/bin/configure-moza, configure-steam-simracing"
    echo ""
    echo "Next steps:"
    if [ -z "$MOZA_TTY" ]; then
        echo "  1. Connect your Moza wheel base and run: configure-moza"
        echo "  2. Close Steam and run: configure-steam-simracing"
    else
        echo "  1. Close Steam and run: configure-steam-simracing"
    fi
    echo ""
    echo "configure-steam-simracing will detect your installed sim racing games"
    echo "and set up launch options so that simd + monocoque + the correct bridge"
    echo "all start automatically when you launch a game from Steam."
    echo ""
    echo "To test without a game: test-monocoque"

# Remove monocoque sim racing telemetry stack
[group("Gaming")]
remove-monocoque:
    #!/usr/bin/env bash
    set -euo pipefail
    CONTAINER="simracing"

    echo "=== Remove Monocoque Telemetry Stack ==="
    echo ""
    echo "This will remove:"
    echo "  - Distrobox container '$CONTAINER'"
    echo "  - Launcher scripts in ~/.local/bin/"
    echo "  - simshmbridge source in ~/.local/share/simracing/"
    echo ""
    echo "Config files in ~/.config/monocoque/ will be KEPT."
    echo ""
    read -rp "Proceed? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi

    # Remove launcher scripts
    for script in start-simd start-monocoque test-monocoque simracing-launch configure-moza configure-steam-simracing; do
        rm -f "$HOME/.local/bin/$script"
    done
    echo "Removed launcher scripts."

    # Remove simshmbridge source
    rm -rf "$HOME/.local/share/simracing"
    echo "Removed simshmbridge source."

    # Remove distrobox container
    if distrobox list 2>/dev/null | grep -q "$CONTAINER"; then
        distrobox rm --force "$CONTAINER"
        echo "Removed distrobox container '$CONTAINER'."
    else
        echo "Container '$CONTAINER' not found, skipping."
    fi

    echo ""
    echo "Monocoque stack removed."
    echo "Config files preserved at ~/.config/monocoque/"
    echo "To remove those too: rm -rf ~/.config/monocoque/"

# Update monocoque and all sim racing telemetry components
[group("Gaming")]
update-monocoque:
    #!/usr/bin/env bash
    set -euo pipefail
    CONTAINER="simracing"

    if ! distrobox list 2>/dev/null | grep -q "$CONTAINER"; then
        echo "ERROR: Container '$CONTAINER' not found."
        echo "Run 'ujust setup-monocoque' first."
        exit 1
    fi

    echo "=== Updating Monocoque Telemetry Stack ==="
    echo ""

    distrobox enter "$CONTAINER" -- bash -c '
        set -euo pipefail

        echo "Updating AUR packages (simapi, simd, monocoque)..."
        yay -Syu --noconfirm

        echo "Updating simshmbridge..."
        INSTALL_DIR="$HOME/.local/share/simracing"
        if [ -d "$INSTALL_DIR/simshmbridge" ]; then
            cd "$INSTALL_DIR/simshmbridge"
            git pull
            make clean 2>/dev/null || true
            make -j$(nproc)
        else
            echo "simshmbridge not found — run ujust setup-monocoque to reinstall."
        fi

        echo ""
        echo "All components updated."
    '
