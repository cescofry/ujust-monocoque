# Sim Racing Telemetry: Moza RPM LEDs on Bazzite

## Goal

Drive the Moza wheel's RPM LEDs (and optionally button LEDs) from live game telemetry on Bazzite (immutable Fedora-based distro), supporting all major sim racing titles.

---

## Architecture

```
Game (Wine/Proton)
    │
    ▼
simshmbridge.exe          Runs inside Wine prefix, copies game-specific
(Wine bridge)             shared memory to Linux-accessible /dev/shm/
    │
    ▼
simd                      Daemon that detects the running game, reads
(simapi daemon)           game-specific shm, writes unified SimData
    │                     struct to /dev/shm/SIMAPI.DAT
    ▼
/dev/shm/SIMAPI.DAT       Normalized telemetry: rpms, maxrpm, gear,
(shared memory file)       speed, simstatus, etc. — same layout for
    │                     every game
    ▼
monocoque                 Reads SIMAPI.DAT, drives Moza RPM LEDs
(device manager)          via serial protocol at configurable FPS
    │
    ▼
Moza Wheel Base           Serial device at /dev/serial/by-id/...
(R5 / R9 / R12 / etc.)   RPM LED bar + button LEDs
```

---

## Components

### 1. simshmbridge (Wine/Proton bridge)

- **Repository:** https://github.com/Spacefreak18/simshmbridge
- **Language:** C (cross-compiled with `mingw-w64-gcc`)
- **What it does:** Runs as a Windows executable inside the Wine/Proton prefix alongside the game. Reads the game's Windows shared memory and mirrors it to a Linux-accessible `/dev/shm/` file.
- **Needed for:** AC, ACC, PC2/AMS2, rFactor2, LMU — any game that uses Windows shared memory APIs.
- **Not needed for:** ETS2/ATS (these write directly to `/dev/shm/`), UDP-based games (Dirt Rally 2, F1, BeamNG).
- **User action:** Run `configure-steam-simracing` after installation — it auto-detects installed games and sets the correct launch option using the `simracing-launch` wrapper. Alternatively, set manually per game (see Per-game Steam launch options table).

### 2. simapi (telemetry library)

- **Repository:** https://github.com/Spacefreak18/simapi
- **Language:** C shared library
- **What it does:** Parses each game's native struct layout and maps it to a unified `SimData` struct. Provides header files for all supported games.
- **Build dependencies:** `cmake`, `gcc`
- **Installation:** Builds as `libsimapi.so`, installed to `/usr/local/lib` (inside the distrobox container).

#### Supported Games (via simapi)

| Tier | Games |
|------|-------|
| Platinum | Assetto Corsa, ACC, Automobilista 2, rFactor 2, LeMans Ultimate |
| Gold | Project Cars 2 |
| Silver | AC Evo, AC Rally, American Truck Sim, Euro Truck Sim 2 |
| Bronze | Live For Speed, BeamNG, Dirt Rally 2 |
| Additional | Richard Burns Rally RSF, Wreckfest 2, F1 2018/2022 |

### 3. simd (telemetry daemon)

- **Location:** Inside the simapi repository (`simapi/simd/`)
- **Language:** C
- **What it does:** Background daemon that:
  1. Polls for running sim games
  2. Detects which game is active
  3. Reads the game-specific shared memory (exposed by simshmbridge)
  4. Maps telemetry into the unified `SimData` struct
  5. Writes it to `/dev/shm/SIMAPI.DAT`
- **Build dependencies:** `yder` (logging), `libuv` (event loop), `argtable2` (CLI args)
- **Config:** `~/.config/simd/simd.config` (default config works without changes)
- **Can run as:** Systemd user service or foreground process

#### SimData struct (key fields at fixed offsets)

```c
typedef struct {
    uint64_t mtick;         // monotonic tick
    uint32_t simstatus;     // 0=off, 1=menu, 2+=active
    uint32_t velocity;      // speed in km/h
    uint32_t rpms;          // current RPM
    uint32_t gear;          // current gear
    uint32_t pulses;
    uint32_t maxrpm;        // rev limit
    uint32_t idlerpm;
    uint32_t maxgears;
    // ... 100+ more fields: tyre temps, suspension, lap times, etc.
} SimData;
```

### 4. monocoque (device manager)

- **Repository:** https://github.com/Spacefreak18/monocoque
- **Language:** C
- **What it does:** Reads `SimData` from `/dev/shm/SIMAPI.DAT` and drives output devices. Supports multiple device types simultaneously.
- **Build dependencies:** `libserialport`, `hidapi`, `libconfig`, `libuv`, `argtable2`, `libxml2`, `portaudio`, `pulseaudio-libs`, `lua`, `libxdg-basedir`
- **Config:** `~/.config/monocoque/monocoque.config`
- **Update rate:** Configurable, default 240 FPS for device updates

#### Moza support in monocoque

Monocoque has two Moza serial implementations:

1. **`moza.c` (old firmware / `MozaR5` subtype):**
   - Takes `rpm` + `maxrpm`, computes percentage
   - Fixed thresholds: 10%, 20%, 30%, 40%, 50%, 60%, 70%, 80%, 90%, 92%
   - Blinking at 94%+
   - 11-byte serial payload with checksum

2. **`moza_new.c` (new firmware / `MozaNew` subtype):**
   - Takes the full `SimData` struct
   - Racing-oriented thresholds: 75%, 79%, 82%, 85%, 87%, 88%, 89%, 90%, 92%, 94%
   - Blink effect at 98% using tick counter
   - Sets custom LED colors on init (green → yellow → red gradient)
   - Same 11-byte serial payload format

#### Monocoque config for Moza RPM LEDs

```
configs = (
    {
        sim = "default";
        car = "default";
        devices = (
        {
            device       = "Serial";
            type         = "Wheel";
            subtype      = "MozaNew";
            devpath      = "/dev/serial/by-id/<your-moza-base-serial>";
        });
    }
);
```

To find your device path:
```bash
ls /dev/serial/by-id/ | grep -i base
```

---

## Why not boxflat or leds4sim?

### boxflat (our 3 recent commits)

The 3 commits (`239f7c2`, `0fe4c8f`, `919da12`) added ~1,370 lines of Python to boxflat:
- `telemetry_reader.py` — manually defines ctypes structs for AC, ACC, rFactor2, LMU, PC2/AMS2, ETS2/ATS, BeamNG with hardcoded shared memory offsets
- `telemetry_handler.py` — polling loop + Moza serial protocol
- `telemetry_cli.py` — CLI interface
- `telemetry.py` — GTK panel

**Problems:**
- Duplicates what simapi already does (and simapi supports more games)
- Mixes telemetry concerns into a wheel configuration tool
- Each new game requires new Python code rather than just config
- Reinvents the Moza serial protocol that monocoque already implements

### leds4sim

A lightweight C++ daemon that reads mmap files at configurable offsets and drives Moza LEDs via serial. It's well-designed and config-driven.

**It could work**, but:
- If you're installing the simapi stack anyway, monocoque gives you more (bass shakers, haptics, tachometers, flags) for the same installation effort
- leds4sim doesn't auto-detect games — you'd need separate configs per game, or point it at `SIMAPI.DAT` with the right offsets
- monocoque is more actively maintained and has a larger community

**leds4sim is a good choice if** you want the absolute minimum footprint and only care about LEDs. But for a full sim racing setup, monocoque is the better investment.

---

## Installation on Bazzite

### Why Bazzite needs special handling

Bazzite is an immutable Fedora-based distro (bootc/OSTree):
- Root filesystem is **read-only** — `dnf install` doesn't work on the host
- `/usr/local` is **immutable** — `sudo make install` fails
- Package layering via `rpm-ostree` requires reboots and is heavy for dev dependencies

### Solution: Distrobox (Arch Linux)

Bazzite ships with Distrobox pre-installed. An **Arch Linux** container is used because
three of the four stack components are available as AUR packages, which dramatically
simplifies installation and updates compared to building from source.

| Component | AUR Package | Notes |
|-----------|-------------|-------|
| simapi | [`simapi-git`](https://aur.archlinux.org/packages/simapi-git) | Shared library — updated 2026-03-21 |
| simd | [`simd-git`](https://aur.archlinux.org/packages/simd-git) | Telemetry daemon |
| monocoque | [`monocoque-git`](https://aur.archlinux.org/packages/monocoque-git) | Device manager (v0.2.0) |
| simshmbridge | **Not on AUR** | Simple `make` with mingw — built manually |

All three AUR packages are maintained by **spacefreak18** (the upstream author).

Benefits over the previous Fedora + build-from-source approach:
- **No manual cmake/make/ldconfig** — AUR PKGBUILDs handle the full build-install chain
- **Automatic dependency resolution** — `yay` pulls in all build and runtime deps
- **Trivial updates** — `yay -Syu` instead of re-running the full build script
- **Proper packaging** — installed files are tracked by pacman, cleanly removable

The container provides:
- Full `pacman` + AUR support
- Shared `$HOME` directory with the host
- Access to `/dev` (serial devices, shared memory)

### ujust recipe

Place this in `/usr/share/ublue-os/just/60-custom.just` to make it available via `ujust`:

```just
# Install monocoque — drives Moza RPM LEDs from live sim telemetry
setup-monocoque:
    #!/usr/bin/env bash
    set -euo pipefail
    CONTAINER="simracing"
    INSTALL_DIR="$HOME/.local/share/simracing"

    echo "=== Monocoque Setup (Moza RPM Telemetry) ==="
    echo ""

    # Check serial device permissions
    if ! groups | grep -q dialout; then
        echo "WARNING: You are not in the 'dialout' group."
        echo "Serial device access may fail. Run:"
        echo "  sudo usermod -aG dialout $USER"
        echo "Then reboot and re-run this recipe."
        echo ""
        read -p "Continue anyway? [y/N]: " cont
        if [[ ! "$cont" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Create the Arch Linux container if it doesn't exist
    if ! distrobox list | grep -q "$CONTAINER"; then
        echo "Creating Arch Linux container '$CONTAINER'..."
        distrobox create \
            -i docker.io/library/archlinux:latest \
            -n "$CONTAINER" \
            --additional-packages \
            "base-devel git mingw-w64-gcc"
    else
        echo "Container '$CONTAINER' already exists, skipping creation."
    fi

    # Install AUR helper and packages inside the container
    distrobox enter "$CONTAINER" -- bash -c '
        set -euo pipefail

        # Install yay (AUR helper) if not present
        if ! command -v yay &>/dev/null; then
            echo "Installing yay AUR helper..."
            cd /tmp
            git clone https://aur.archlinux.org/yay-bin.git
            cd yay-bin
            makepkg -si --noconfirm
            cd / && rm -rf /tmp/yay-bin
        fi

        # Install simapi, simd, and monocoque from AUR
        echo "Installing AUR packages..."
        yay -S --needed --noconfirm simapi-git simd-git monocoque-git

        # Build simshmbridge manually (not on AUR)
        INSTALL_DIR="$HOME/.local/share/simracing"
        mkdir -p "$INSTALL_DIR"
        cd "$INSTALL_DIR"
        if [ ! -d "simshmbridge" ]; then
            echo "Cloning simshmbridge..."
            git clone "https://github.com/Spacefreak18/simshmbridge.git"
        else
            echo "simshmbridge already cloned, pulling latest..."
            cd simshmbridge && git pull && cd ..
        fi
        echo "Building simshmbridge..."
        cd "$INSTALL_DIR/simshmbridge"
        make clean 2>/dev/null || true
        make -j$(nproc)

        echo "All components installed successfully."
    '

    # Create launcher scripts on the host
    mkdir -p "$HOME/.local/bin"

    cat > "$HOME/.local/bin/start-simd" << 'SCRIPT'
#!/usr/bin/env bash
distrobox enter simracing -- simd "$@"
SCRIPT
    chmod +x "$HOME/.local/bin/start-simd"

    cat > "$HOME/.local/bin/start-monocoque" << 'SCRIPT'
#!/usr/bin/env bash
distrobox enter simracing -- monocoque play "$@"
SCRIPT
    chmod +x "$HOME/.local/bin/start-monocoque"

    cat > "$HOME/.local/bin/test-monocoque" << 'SCRIPT'
#!/usr/bin/env bash
distrobox enter simracing -- monocoque test -vv "$@"
SCRIPT
    chmod +x "$HOME/.local/bin/test-monocoque"

    # simracing-launch: unified wrapper that starts simd + monocoque + bridge
    cat > "$HOME/.local/bin/simracing-launch" << 'SCRIPT'
#!/usr/bin/env bash
# Unified sim racing launcher — starts telemetry stack and runs the game.
# Usage: simracing-launch [bridge_exe|none] %command%
#   bridge_exe: path to simshmbridge .exe, or "none" for games with native shm/UDP
set -euo pipefail

BRIDGE="$1"; shift

# Start simd if not already running
if ! pgrep -xf ".*simd" >/dev/null 2>&1; then
    echo "[simracing] Starting simd..."
    distrobox enter simracing -- simd &
    SIMD_PID=$!
    sleep 2  # let simd initialize
else
    echo "[simracing] simd already running."
    SIMD_PID=""
fi

# Start monocoque if not already running
if ! pgrep -xf ".*monocoque.*play" >/dev/null 2>&1; then
    echo "[simracing] Starting monocoque..."
    distrobox enter simracing -- monocoque play &
    MONO_PID=$!
else
    echo "[simracing] monocoque already running."
    MONO_PID=""
fi

# Launch the game (with or without bridge)
if [ "$BRIDGE" != "none" ]; then
    SIMD_BRIDGE_EXE="$BRIDGE" "$@"
else
    "$@"
fi

# Cleanup when game exits
echo "[simracing] Game exited, stopping telemetry stack..."
[ -n "$SIMD_PID" ] && kill "$SIMD_PID" 2>/dev/null || true
[ -n "$MONO_PID" ] && kill "$MONO_PID" 2>/dev/null || true
SCRIPT
    chmod +x "$HOME/.local/bin/simracing-launch"

    # configure-moza: auto-detect Moza base serial device and patch monocoque config
    cat > "$HOME/.local/bin/configure-moza" << 'SCRIPT'
#!/usr/bin/env bash
# Detects the Moza wheel base serial device and configures monocoque.
set -euo pipefail

CONFIG="$HOME/.config/monocoque/monocoque.config"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: monocoque config not found at $CONFIG"
    echo "Run 'ujust setup-monocoque' first."
    exit 1
fi

echo "Scanning /dev/serial/by-id/ for Moza wheel base..."
MOZA_DEV=$(ls /dev/serial/by-id/ 2>/dev/null | grep -iE "moza|gudsen" | grep -i base | head -1 || true)

if [ -z "$MOZA_DEV" ]; then
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

FULL_PATH="/dev/serial/by-id/$MOZA_DEV"
echo "Found: $FULL_PATH"

# Check if already configured with this device
if grep -q "$MOZA_DEV" "$CONFIG" 2>/dev/null; then
    echo "monocoque config already points to this device. Nothing to do."
    exit 0
fi

# Replace placeholder or existing device path
if grep -q "CHANGE_ME_TO_YOUR_MOZA_BASE" "$CONFIG"; then
    sed -i "s|CHANGE_ME_TO_YOUR_MOZA_BASE|$FULL_PATH|" "$CONFIG"
elif grep -q 'devpath.*=.*"/dev/serial/by-id/' "$CONFIG"; then
    sed -i "s|devpath.*=.*\"/dev/serial/by-id/[^\"]*\"|devpath      = \"$FULL_PATH\"|" "$CONFIG"
else
    echo "WARNING: Could not find devpath line to update in $CONFIG"
    echo "Please manually set devpath to: $FULL_PATH"
    exit 1
fi

echo "Updated $CONFIG with device: $FULL_PATH"
echo ""
echo "You can verify with: test-monocoque"
SCRIPT
    chmod +x "$HOME/.local/bin/configure-moza"

    # configure-steam-simracing: auto-detect installed sim racing games and set launch options
    cat > "$HOME/.local/bin/configure-steam-simracing" << 'SCRIPT'
#!/usr/bin/env bash
# Detects installed sim racing games in Steam and sets up launch options
# to use the simracing-launch wrapper (simd + monocoque + bridge in one command).
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
# Parse libraryfolders.vdf for library paths
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
read -p "Select games to configure (e.g. 1,3 or A for all): " SELECTION

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

        # Use python3 to safely modify VDF (it's a nested key-value format)
        python3 - "$LOCALCONFIG" "$APPID" "$LAUNCH_OPT" << 'PYEOF'
import sys, re

config_path, appid, launch_opt = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_path, 'r') as f:
    content = f.read()

# VDF is a nested brace format. We need to find the app's section under
# "UserLocalConfigStore" > "Software" > "Valve" > "Steam" > "apps" > appid
# and set "LaunchOptions" within it.

# Pattern to find the app block (handles both existing and missing LaunchOptions)
# This is a simplified approach - VDF is not easily regex-parseable for deeply nested keys
# We look for the appid block pattern
app_pattern = rf'("{appid}"[\s]*\{{[^}}]*)\}}'
match = re.search(app_pattern, content)

if match:
    block = match.group(1)
    # Check if LaunchOptions already exists
    lo_pattern = r'"LaunchOptions"\s*"[^"]*"'
    if re.search(lo_pattern, block):
        new_block = re.sub(lo_pattern, f'"LaunchOptions"\t\t"{launch_opt}"', block)
    else:
        # Add LaunchOptions before the closing brace
        new_block = block + f'\n\t\t\t\t\t\t\t"LaunchOptions"\t\t"{launch_opt}"'
    content = content.replace(block, new_block)
    with open(config_path, 'w') as f:
        f.write(content)
    print(f"  Configured: {appid}")
else:
    print(f"  App {appid} not found in localconfig.vdf (may not have been launched yet)")
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
    chmod +x "$HOME/.local/bin/configure-steam-simracing"

    # Setup monocoque config (simd config is handled by the AUR package)
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
            devpath      = "/dev/serial/by-id/CHANGE_ME_TO_YOUR_MOZA_BASE";
        });
    }
);
MONOCONF
        echo "Created monocoque config at ~/.config/monocoque/monocoque.config"
    fi

    # Auto-detect Moza device and configure if wheel is connected
    MOZA_DEV=$(ls /dev/serial/by-id/ 2>/dev/null | grep -iE "moza|gudsen" | grep -i base | head -1 || true)
    if [ -n "$MOZA_DEV" ]; then
        FULL_PATH="/dev/serial/by-id/$MOZA_DEV"
        sed -i "s|CHANGE_ME_TO_YOUR_MOZA_BASE|$FULL_PATH|" \
            "$HOME/.config/monocoque/monocoque.config"
        echo "Auto-detected Moza base: $FULL_PATH"
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
    if [ -z "$MOZA_DEV" ]; then
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
```

### Usage

```bash
# One command to install monocoque and its dependencies
ujust setup-monocoque

# If wheel wasn't connected during install, plug it in and run:
configure-moza

# Close Steam, then auto-configure launch options for installed games:
configure-steam-simracing

# Now just launch any sim from Steam — everything starts automatically!

# Update all components
distrobox enter simracing -- yay -Syu --noconfirm
```

---

## Post-install scripts

### `configure-moza`

Auto-detects the Moza wheel base serial device and patches `monocoque.config`:
- Scans `/dev/serial/by-id/` for Moza/Gudsen base devices
- Updates the `devpath` in `~/.config/monocoque/monocoque.config`
- If no device found: tells user to check USB connection, power, and `dialout` group, then re-run

Called automatically during install if the wheel is connected. If not, the user runs it later.

### `configure-steam-simracing`

Auto-detects installed sim racing games and sets Steam launch options:
- Scans Steam library folders for known sim racing app IDs
- Presents a menu of found games for the user to select
- Sets each game's launch option to `simracing-launch <bridge> %command%`
- Creates a timestamped backup of `localconfig.vdf` before modifying
- Requires Steam to be closed (checks and warns if running)

### `simracing-launch`

Unified wrapper script set as Steam launch option for each game:
- Starts `simd` (if not already running) inside the distrobox container
- Starts `monocoque play` (if not already running) inside the distrobox container
- Sets up the bridge env var (or skips it for native shm/UDP games)
- Runs the game
- Stops `simd` and `monocoque` when the game exits

Usage: `simracing-launch <bridge_exe|none> %command%`

---

## Runtime flow

1. The user **launches a game from Steam**.
2. **`simracing-launch`** (set as the Steam launch option) automatically:
   - Starts `simd` inside the distrobox container (watches for sim games)
   - Starts `monocoque play` inside the distrobox (drives Moza LEDs)
   - Launches `simshmbridge.exe` alongside the game (if needed)
3. `simshmbridge.exe` runs inside Wine, exposing telemetry to `/dev/shm/`.
4. `simd` detects the game, reads the game-specific shared memory, and writes normalized data to `/dev/shm/SIMAPI.DAT`.
5. `monocoque` reads `SIMAPI.DAT` and sends RPM LED commands to the Moza base via serial.
6. The Moza wheel's RPM LEDs light up in real time based on engine RPM.
7. When the game exits, `simracing-launch` stops `simd` and `monocoque`.

---

## Per-game Steam launch options

Set automatically by `configure-steam-simracing`, or manually:

| Game | App ID | Launch Option |
|------|--------|--------------|
| Assetto Corsa | 244210 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/acbridge.exe %command%` |
| ACC | 805550 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/acbridge.exe %command%` |
| AMS2 | 1066890 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/pcars2bridge.exe %command%` |
| Project Cars 2 | 378860 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/pcars2bridge.exe %command%` |
| rFactor 2 | 365960 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/rf2bridge.exe %command%` |
| LeMans Ultimate | 2069810 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/rf2bridge.exe %command%` |
| ETS2 | 227300 | `simracing-launch none %command%` |
| ATS | 270880 | `simracing-launch none %command%` |
| BeamNG | 284160 | `simracing-launch none %command%` |

---

## Troubleshooting

### Serial device not found
```bash
# Check if device exists
ls /dev/serial/by-id/ | grep -i base

# Check group membership
groups | grep dialout

# Fix permissions (requires reboot)
sudo usermod -aG dialout $USER
```

### simd doesn't detect the game
```bash
# Check if shared memory files exist
ls /dev/shm/

# For AC/ACC, look for: acpmf_physics, acpmf_graphics, acpmf_static
# For AMS2/PC2, look for: $pcars2$
# For ETS2, look for: SCS/SCSTelemetry

# Verify the bridge is running
ps aux | grep bridge.exe
```

### monocoque shows 0 RPM
1. Verify `simd` output shows the game was detected
2. Check that the game has shared memory enabled (AMS2 needs this in settings)
3. Verify `SIMAPI.DAT` exists: `ls -la /dev/shm/SIMAPI.DAT`

### Rebuilding / updating
```bash
# Update AUR packages (simapi, simd, monocoque)
distrobox enter simracing -- yay -Syu --noconfirm

# Re-run the recipe to also rebuild simshmbridge
ujust setup-monocoque
```

---

## Future possibilities

- **Bass shakers:** Monocoque already supports haptic effects (engine rumble, tyre slip/lock, ABS) via sound devices or serial-connected motors. Add `Sound` or `Serial` `Haptic` entries to the monocoque config.
- **Additional Moza devices:** Button LEDs, flag indicators — `moza_new.c` already sends button color payloads, just needs config entries.
- **systemd integration:** `simd` and `monocoque` could run as systemd user services instead of being managed by `simracing-launch`, allowing them to persist across game sessions and start on login.
