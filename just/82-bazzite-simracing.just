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
        echo "ERROR: ~/.local/bin is not in your PATH."
        echo "Run: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
        exit 1
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
        if systemctl is-active --quiet ModemManager 2>/dev/null; then
            echo ""
            echo "WARNING: ModemManager is currently running on your system."
            echo "Moza wheel bases use USB serial devices that ModemManager may claim,"
            echo "preventing monocoque from communicating with the wheel."
            echo ""
            echo "A udev rule can tell ModemManager to ignore Moza devices (vendor 346e)."
            echo "This only affects Moza USB devices — other modems will work normally."
            echo ""
            echo "If you skip this, ModemManager may interfere with your wheel base."
            echo ""
            read -rp "Install udev rule to prevent ModemManager from grabbing Moza devices? [Y/n]: " mm_confirm
            if [[ "$mm_confirm" =~ ^[Nn]$ ]]; then
                echo ""
                echo "Skipped udev rule. If monocoque can't talk to your wheel, run:"
                echo "  sudo tee $UDEV_RULE <<< 'ACTION==\"add|change\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"346e\", ENV{ID_MM_DEVICE_IGNORE}=\"1\"'"
                echo "  sudo udevadm control --reload-rules && sudo udevadm trigger"
                echo ""
            else
                echo "Installing udev rule..."
                echo 'ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="346e", ENV{ID_MM_DEVICE_IGNORE}="1"' | sudo tee "$UDEV_RULE" >/dev/null
                sudo udevadm control --reload-rules
                sudo udevadm trigger
            fi
        else
            # ModemManager not running — safe to install the rule silently
            echo 'ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="346e", ENV{ID_MM_DEVICE_IGNORE}="1"' | sudo tee "$UDEV_RULE" >/dev/null
            sudo udevadm control --reload-rules
            sudo udevadm trigger
        fi
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

    # Install launcher scripts to ~/.local/bin from repo scripts/
    REPO_DIR="{{ justfile_directory() }}/.."
    mkdir -p "$SCRIPTS_DIR"
    for script in start-simd start-monocoque test-monocoque simracing-launch configure-moza configure-steam-simracing; do
        cp "$REPO_DIR/scripts/$script" "$SCRIPTS_DIR/$script"
        chmod +x "$SCRIPTS_DIR/$script"
    done

    # Setup monocoque config
    mkdir -p "$HOME/.config/monocoque"
    if [ ! -f "$HOME/.config/monocoque/monocoque.config" ]; then
        cp "$REPO_DIR/configs/monocoque.config" "$HOME/.config/monocoque/monocoque.config"
        echo "Created monocoque config at ~/.config/monocoque/monocoque.config"
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
    echo "  1. Connect your Moza wheel base and run: configure-moza"
    echo "  2. Close Steam and run: configure-steam-simracing"
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
