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
│   ├── configure-steam-simracing    # Auto-configure Steam launch options
│   └── telemetry-diagnose           # Runtime diagnostic logger
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
- Install a udev rule to prevent ModemManager from grabbing Moza devices
- Create an Arch Linux distrobox container named `simracing`
- Install `simapi-git`, `simd-git`, `monocoque-git` from AUR
- Clone and build `simshmbridge` (not on AUR)
- Install launcher scripts to `~/.local/bin/`
- Create `~/.config/monocoque/monocoque.config`
- Auto-detect your Moza wheel base (if connected)

2. Configure your Moza wheel (if it wasn't connected during install):

```bash
configure-moza
```

3. Close Steam, then auto-configure launch options:

```bash
configure-steam-simracing
```

4. Launch any sim from Steam — everything starts automatically.

### Manual Installation (without ujust)

You can run the scripts directly:

```bash
# Copy scripts to ~/.local/bin/
cp scripts/* ~/.local/bin/
chmod +x ~/.local/bin/{start-simd,start-monocoque,test-monocoque,simracing-launch,configure-moza,configure-steam-simracing,telemetry-diagnose}

# Then follow the distrobox setup steps from the ujust recipe manually
```

## Usage

### Automatic (recommended)

After running `configure-steam-simracing`, just launch games from Steam. The `simracing-launch` wrapper handles everything:

1. Stops Boxflat if running (serial port conflict)
2. Starts `simd` inside the distrobox container
3. Starts `monocoque play` inside the distrobox container
4. Injects the bridge `.exe` into the game's Wine session via a VBScript wrapper (if needed)
5. Cleans up when the game exits

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

Set automatically by `configure-steam-simracing`, or set manually in Steam.

`configure-steam-simracing` creates per-game launcher aliases in `~/.local/bin/` and configures Steam to use them:

| Game | Alias | Bridge |
|------|-------|--------|
| Assetto Corsa | `simracing-launch-ac` | `acbridge.exe` |
| ACC | `simracing-launch-acc` | `acbridge.exe` |
| AMS2 | `simracing-launch-ams2` | `pcars2bridge.exe` |
| Project Cars 2 | `simracing-launch-pcars2` | `pcars2bridge.exe` |
| rFactor 2 | `simracing-launch-rf2` | `rf2bridge.exe` |
| LeMans Ultimate | `simracing-launch-lmu` | `rf2bridge.exe` |
| ETS2 | `simracing-launch-ets2` | none |
| ATS | `simracing-launch-ats` | none |
| BeamNG | `simracing-launch-beamng` | none |

Each alias calls `simracing-launch` with the correct bridge path. The Steam launch option for each game is set to `simracing-launch-<alias> %command%`.

To set launch options manually instead (without using `configure-steam-simracing`):

```
simracing-launch <bridge_exe_path|none> %command%
```

## Scripts Reference

### `start-simd`

Thin wrapper that runs `simd` inside the `simracing` distrobox container. Forwards all arguments.

```bash
start-simd          # start the telemetry daemon
start-simd --help   # show simd help
```

`simd` monitors `/dev/shm/` for game-specific shared memory files, detects which sim is running, and writes a unified `SimData` struct to `/dev/shm/SIMAPI.DAT`.

### `start-monocoque`

Thin wrapper that runs `monocoque play` inside the `simracing` distrobox container. Forwards all arguments.

```bash
start-monocoque     # start reading telemetry and driving LEDs
```

Reads from `/dev/shm/SIMAPI.DAT` and sends RPM LED commands to the Moza wheel base over serial. Uses the config at `~/.config/monocoque/monocoque.config`.

### `test-monocoque`

Thin wrapper that runs `monocoque test -vv` inside the `simracing` distrobox container. Validates the config, detects the serial device, and sends test LED patterns to the wheel.

```bash
test-monocoque      # validate config and test LED output
```

If your LEDs light up, the serial connection and config are correct.

### `simracing-launch`

Unified Steam launch wrapper. Starts the full telemetry stack and launches the game.

```bash
simracing-launch <bridge_exe|none> %command%
```

What it does, in order:

1. **Kills Boxflat** if running — Boxflat holds the serial port and blocks monocoque
2. **Starts `simd`** (via `start-simd`) if not already running
3. **Starts `monocoque play`** (via `start-monocoque`) if not already running
4. **Injects the bridge** (if a bridge `.exe` path is given, not `none`):
   - Copies the bridge `.exe` into the game directory
   - Creates a VBScript wrapper (`simracing_wrapper.vbs`) that launches the bridge hidden, runs the game, and kills the bridge on exit
   - Replaces the game `.exe` in the Steam launch args with the wrapper
5. **Launches the game** with the (possibly modified) arguments
6. **Cleans up** on exit — kills `simd` and `monocoque` processes it started

### `configure-moza`

Detects the Moza wheel base serial device and updates the monocoque config.

```bash
configure-moza
```

1. Scans `/dev/serial/by-id/` for devices matching `moza`/`gudsen` + `base` (case-insensitive)
2. If found, updates the `devpath` in `~/.config/monocoque/monocoque.config`
3. Prompts for wheel base subtype:
   - **MozaNew** (default) — R9, R12, R16, R21 and other recent bases
   - **MozaR5** — R5 base
4. Skips if the config already points to the detected device

### `configure-steam-simracing`

Detects installed sim racing games in Steam and configures their launch options to use the telemetry stack.

```bash
configure-steam-simracing
```

1. **Requires Steam to be closed** — Steam overwrites `localconfig.vdf` on exit, which would undo changes. Offers to close Steam if it's running.
2. **Scans Steam library folders** for installed supported games by checking `appmanifest_*.acf` files
3. **Shows found games** and lets you select which to configure (individual, multiple, or all)
4. **Modifies `localconfig.vdf`** to set each game's launch option (creates a timestamped backup first)
5. **Creates per-game launcher aliases** in `~/.local/bin/` (e.g., `simracing-launch-ac`, `simracing-launch-acc`) — each alias calls `simracing-launch` with the correct bridge path
6. Uses Python to safely parse and modify Steam's VDF format

### `telemetry-diagnose`

Runtime diagnostic logger for debugging the telemetry pipeline while a game is running.

```bash
telemetry-diagnose          # run for 60 seconds (default)
telemetry-diagnose 120      # run for 120 seconds
```

Samples the system state once per second and writes to `/tmp/telemetry-diag.log`. Each sample records:

- **Process checks** — whether `simd`, `monocoque`, the bridge, and wineserver are running
- **Shared memory files** — existence and size of `acpmf_physics`, `acpmf_graphics`, `acpmf_static`, `acpmf_crewchief`, and `SIMAPI.DAT`
- **Data content** — hex dump of the first bytes of physics, graphics, and SIMAPI shared memory (to verify non-zero data is flowing)
- **Serial device** — whether `/dev/ttyACM0` exists and its permissions
- **CPU usage** — monocoque CPU percentage (high CPU on empty data indicates a spin-wait issue)

Run this in a separate terminal while playing to capture a diagnostic snapshot for troubleshooting.

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

If something isn't working, run `telemetry-diagnose` in a separate terminal to capture a diagnostic log at `/tmp/telemetry-diag.log`.

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
