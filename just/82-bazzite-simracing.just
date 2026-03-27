# vim: set ft=make :

# Repo directory (parent of just/)
repo_dir := justfile_directory() / ".."

# Install scripts and config from repo to ~/.local/bin and ~/.config/monocoque
[private]
[no-cd]
install-scripts repo=repo_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    SCRIPTS_DIR="$HOME/.local/bin"
    REPO="{{repo}}"

    if [ ! -d "$REPO/scripts" ]; then
        echo "ERROR: scripts/ directory not found at $REPO/scripts"
        echo "Make sure you are running this from the ujust-monocoque repo."
        exit 1
    fi

    echo "Installing scripts to $SCRIPTS_DIR..."
    mkdir -p "$SCRIPTS_DIR"
    cp "$REPO/scripts/"* "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/start-simd" \
             "$SCRIPTS_DIR/start-monocoque" \
             "$SCRIPTS_DIR/test-monocoque" \
             "$SCRIPTS_DIR/simracing-launch" \
             "$SCRIPTS_DIR/configure-moza" \
             "$SCRIPTS_DIR/configure-steam-simracing"

    echo "Installed: start-simd, start-monocoque, test-monocoque, simracing-launch,"
    echo "           configure-moza, configure-steam-simracing"

    # Install monocoque config template (only if no config exists yet)
    mkdir -p "$HOME/.config/monocoque"
    if [ ! -f "$HOME/.config/monocoque/monocoque.config" ]; then
        cp "$REPO/configs/monocoque.config" "$HOME/.config/monocoque/monocoque.config"
        echo "Created monocoque config at ~/.config/monocoque/monocoque.config"
    else
        echo "Monocoque config already exists, skipping."
    fi

# Install monocoque sim racing telemetry stack (Moza RPM LEDs)
[group("Gaming")]
setup-monocoque:
    #!/usr/bin/env bash
    set -euo pipefail
    CONTAINER="simracing"
    INSTALL_DIR="$HOME/.local/share/simracing"

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

    # Install scripts and config from repo
    just {{justfile()}} install-scripts

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
        sed -i "s|CHANGE_ME_TO_YOUR_MOZA_BASE|$MOZA_TTY|" \
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

# Reinstall scripts and config from repo (no distrobox rebuild)
[group("Gaming")]
update-monocoque-scripts:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Updating Monocoque Scripts ==="
    echo ""
    just {{justfile()}} install-scripts
    echo ""
    echo "Scripts updated. No container changes made."
    echo "To also update AUR packages and simshmbridge, run: update-monocoque"

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

    # Reinstall scripts from repo
    just {{justfile()}} install-scripts
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
