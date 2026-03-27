# Monocoque Sim Racing Telemetry for Bazzite

Drives Moza wheel RPM LEDs from live game telemetry on [Bazzite](https://bazzite.gg/) using the [monocoque](https://github.com/Spacefreak18/monocoque) / [simapi](https://github.com/Spacefreak18/simapi) stack.

## What It Does

This recipe installs a telemetry pipeline that reads real-time RPM data from sim racing games and drives the LED bar on your Moza wheel base:

```
Game (Wine/Proton)
    |
    v
simshmbridge.exe          Copies game shared memory to Linux /dev/shm/
    |
    v
simd                      Detects running game, writes unified SimData
    |
    v
/dev/shm/SIMAPI.DAT       Normalized telemetry for all games
    |
    v
monocoque                 Reads SimData, drives Moza LEDs via serial
    |
    v
Moza Wheel Base            RPM LED bar lights up in real time
```

## Supported Games

| Tier | Games |
|------|-------|
| Platinum | Assetto Corsa, ACC, Automobilista 2, rFactor 2, LeMans Ultimate |
| Gold | Project Cars 2 |
| Silver | AC Evo, AC Rally, American Truck Sim, Euro Truck Sim 2 |
| Bronze | Live For Speed, BeamNG, Dirt Rally 2 |

## Prerequisites

- **Bazzite** (or any immutable Fedora with distrobox)
- **Moza wheel base** (R5, R9, R12, R16, or R21) connected via USB
- **Steam** with at least one supported sim racing game installed

## Repository Structure

```
ujust-monocoque/
├── just/
│   └── 82-bazzite-simracing.just   # ujust recipe (setup/remove/update)
├── scripts/
│   ├── start-simd                   # Start simd telemetry daemon
│   ├── start-monocoque              # Start monocoque device manager
│   ├── test-monocoque               # Test monocoque config (verbose)
│   ├── simracing-launch             # Unified Steam launch wrapper
│   ├── configure-moza               # Auto-detect Moza serial device
│   └── configure-steam-simracing    # Auto-configure Steam launch options
├── configs/
│   └── monocoque.config             # Default monocoque config template
├── SIMRACING-TELEMETRY-PLAN.md      # Architecture & design document
└── README.md                        # This file
```

## Installation

### On Bazzite (ujust)

1. Run the recipe directly from this repo:

```bash
just --justfile just/82-bazzite-simracing.just setup-monocoque
```

> **Note:** Bazzite's filesystem is immutable — you cannot copy files to `/usr/share/ublue-os/just/`. Use `just --justfile` to run recipes from any writable location. If you want `ujust` integration, you can temporarily unlock the filesystem with `sudo ostree admin unlock`, but this resets on reboot.

This will:
- Check you are in the `dialout` group (needed for serial access)
- Create an Arch Linux distrobox container named `simracing`
- Install `simapi-git`, `simd-git`, `monocoque-git` from AUR
- Clone and build `simshmbridge` (not on AUR)
- Install launcher scripts to `~/.local/bin/`
- Create `~/.config/monocoque/monocoque.config`
- Auto-detect your Moza wheel base (if connected)

3. Configure your Moza wheel (if it wasn't connected during install):

```bash
configure-moza
```

4. Close Steam, then auto-configure launch options:

```bash
configure-steam-simracing
```

5. Launch any sim from Steam — everything starts automatically.

### Manual Installation (without ujust)

You can run the scripts directly:

```bash
# Copy scripts to ~/.local/bin/
cp scripts/* ~/.local/bin/
chmod +x ~/.local/bin/{start-simd,start-monocoque,test-monocoque,simracing-launch,configure-moza,configure-steam-simracing}

# Then follow the distrobox setup steps from the ujust recipe manually
```

## Usage

### Automatic (recommended)

After running `configure-steam-simracing`, just launch games from Steam. The `simracing-launch` wrapper handles everything:

1. Starts `simd` inside the distrobox container
2. Starts `monocoque play` inside the distrobox container
3. Launches `simshmbridge.exe` alongside the game (if needed)
4. Cleans up when the game exits

### Manual

```bash
# Start the telemetry daemon
start-simd

# In another terminal, start the device manager
start-monocoque

# Launch your game from Steam
# (set launch option manually: simracing-launch <bridge_path|none> %command%)
```

### Per-Game Launch Options

Set automatically by `configure-steam-simracing`, or set manually in Steam:

| Game | Launch Option |
|------|--------------|
| Assetto Corsa | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/acbridge.exe %command%` |
| ACC | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/acbridge.exe %command%` |
| AMS2 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/pcars2bridge.exe %command%` |
| Project Cars 2 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/pcars2bridge.exe %command%` |
| rFactor 2 | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/rf2bridge.exe %command%` |
| LeMans Ultimate | `simracing-launch ~/.local/share/simracing/simshmbridge/assets/rf2bridge.exe %command%` |
| ETS2 | `simracing-launch none %command%` |
| ATS | `simracing-launch none %command%` |
| BeamNG | `simracing-launch none %command%` |

## Testing

### 1. Verify the container

```bash
distrobox list
# Should show "simracing" container

distrobox enter simracing -- simd --help
distrobox enter simracing -- monocoque --help
```

### 2. Test monocoque config

```bash
test-monocoque
```

This runs `monocoque test -vv` which validates your config, detects the serial device, and sends test LED patterns to the wheel. If your LEDs light up, the stack is working.

### 3. Test the full pipeline (without a game)

```bash
# Terminal 1: start simd
start-simd

# Terminal 2: start monocoque
start-monocoque

# Terminal 3: check shared memory
ls -la /dev/shm/SIMAPI.DAT
```

### 4. Test with a game

Launch any supported game from Steam. Watch the terminal output from `simracing-launch` to verify:
- `simd` detects the running game
- `monocoque` reads telemetry and drives LEDs
- LEDs respond to RPM changes in-game

### 5. Script linting

```bash
# Lint all scripts with shellcheck
shellcheck scripts/*
```

## Updating

```bash
# Via just (from repo directory)
just --justfile just/82-bazzite-simracing.just update-monocoque

# Or manually
distrobox enter simracing -- yay -Syu --noconfirm
```

## Uninstalling

```bash
# Via just (from repo directory)
just --justfile just/82-bazzite-simracing.just remove-monocoque

# To also remove config:
rm -rf ~/.config/monocoque/
```

## Deploying to Bazzite

### For Personal Use

Run the recipe directly with `just`:

```bash
just --justfile just/82-bazzite-simracing.just setup-monocoque
```

Bazzite's filesystem is immutable, so you cannot copy files to `/usr/share/ublue-os/just/`. If you want `ujust` integration (so the recipe shows up in `ujust --list`), you can temporarily unlock the filesystem:

```bash
sudo ostree admin unlock
sudo cp just/82-bazzite-simracing.just /usr/share/ublue-os/just/82-bazzite-simracing.just
ujust setup-monocoque
```

> **Note:** `ostree admin unlock` is temporary — the overlay resets on reboot. For a persistent `ujust` integration, contribute upstream (see below) or build a custom image.

### For a Bazzite PR

To contribute this upstream to Bazzite:

1. Fork the [Bazzite repository](https://github.com/ublue-os/bazzite)
2. Place the recipe file at `system_files/shared/usr/share/ublue-os/just/82-bazzite-simracing.just`
3. Follow Bazzite's [contribution guidelines](https://github.com/ublue-os/bazzite/blob/main/CONTRIBUTING.md)
4. Ensure the recipe follows Bazzite conventions:
   - Uses `[group("Gaming")]` attribute for recipe categorization
   - Recipes are idempotent (safe to re-run)
   - Includes both setup and removal recipes
   - Uses `distrobox` for all package management (no `rpm-ostree`)
   - All scripts use `set -euo pipefail` for safety
   - Interactive prompts use `read -rp` (with `-r` to prevent backslash issues)

### Conventions Followed

- **Numbered file naming:** `82-bazzite-simracing.just` follows Bazzite's convention where `82-*` files are for app installation/setup
- **Group attribute:** `[group("Gaming")]` categorizes recipes in `ujust --list`
- **Idempotent:** Re-running `setup-monocoque` skips already-completed steps
- **Cleanup recipe:** `remove-monocoque` provides clean uninstallation
- **Update recipe:** `update-monocoque` updates all components in-place
- **Distrobox isolation:** All build tools and libraries stay inside the container, keeping the host immutable
- **AUR packages:** Uses official AUR packages maintained by upstream author for 3 of 4 components

## Troubleshooting

### Serial device not found

```bash
# Check if device exists
ls /dev/serial/by-id/ | grep -i base

# Check group membership
groups | grep dialout

# Fix permissions (requires logout/login)
sudo usermod -aG dialout $USER
```

### simd doesn't detect the game

```bash
# Check if shared memory files exist
ls /dev/shm/

# For AC/ACC, look for: acpmf_physics, acpmf_graphics, acpmf_static
# For AMS2/PC2: $pcars2$
# For ETS2: SCS/SCSTelemetry

# Verify the bridge is running (for games that need it)
ps aux | grep bridge.exe
```

### monocoque shows 0 RPM

1. Verify `simd` output shows the game was detected
2. Check the game has shared memory enabled (AMS2 needs this in settings)
3. Verify `SIMAPI.DAT` exists: `ls -la /dev/shm/SIMAPI.DAT`

### Container issues

```bash
# Recreate the container from scratch
distrobox rm --force simracing
ujust setup-monocoque
```

## Architecture

See [SIMRACING-TELEMETRY-PLAN.md](SIMRACING-TELEMETRY-PLAN.md) for the full architecture document, including component details, the SimData struct layout, and design rationale.

## Credits

- [monocoque](https://github.com/Spacefreak18/monocoque) by Spacefreak18 — device manager
- [simapi](https://github.com/Spacefreak18/simapi) / simd by Spacefreak18 — telemetry library and daemon
- [simshmbridge](https://github.com/Spacefreak18/simshmbridge) by Spacefreak18 — Wine/Proton shared memory bridge
