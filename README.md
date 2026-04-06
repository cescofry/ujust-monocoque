# Simracing Utilities

Convenience tools for the [monocoque](https://github.com/Spacefreak18/monocoque) sim racing telemetry stack. Automates game launching, Moza wheel configuration, Steam setup, and diagnostics.

## Prerequisites

- **Monocoque installed** — see [monocoque](https://github.com/Spacefreak18/monocoque) for installation (including a [distrobox installer](https://github.com/Spacefreak18/monocoque/tree/master/tools/distro/distrobox) for immutable distros)
- **Moza wheel base** (R5, R9, R12, R16, or R21) connected via USB
- **Steam** with at least one supported sim racing game

## Installation

```bash
bash install.sh
```

This checks that monocoque is installed, then copies the utility scripts to `~/.local/bin/`.

To uninstall:

```bash
bash uninstall.sh
```

## Tools

### `configure-moza`

Auto-detects your Moza wheel base serial device and updates the monocoque config.

```bash
configure-moza
```

Scans `/dev/serial/by-id/` for Moza/Gudsen base devices, updates `devpath` in `~/.config/monocoque/monocoque.config`, and prompts for wheel subtype (MozaNew or MozaR5).

### `configure-steam-simracing`

Detects installed sim racing games and configures Steam launch options to use the telemetry stack.

```bash
configure-steam-simracing
```

Requires Steam to be closed. Scans your Steam library, lets you select which games to configure, and sets up per-game launcher aliases that automatically start simd + monocoque + the correct bridge when you launch a game.

### `simracing-launch`

Unified game launcher that manages the full telemetry stack lifecycle.

```bash
simracing-launch <bridge_exe|none> %command%
```

What it does:
1. Stops Boxflat if running (serial port conflict)
2. Starts `simd` and `monocoque` if not already running
3. Injects the bridge `.exe` into the game's Wine session (if needed)
4. Launches the game
5. Cleans up on exit

Normally called via per-game aliases created by `configure-steam-simracing`, not directly.

### `telemetry-diagnose`

Runtime diagnostic logger for troubleshooting.

```bash
telemetry-diagnose          # 60 seconds (default)
telemetry-diagnose 120      # 120 seconds
```

Samples process status, shared memory files, data content, serial device, and CPU usage once per second. Writes to `/tmp/telemetry-diag.log`.

## Supported Games

| Game | Bridge | Alias |
|------|--------|-------|
| Assetto Corsa | `acbridge.exe` | `simracing-launch-ac` |
| ACC | `acbridge.exe` | `simracing-launch-acc` |
| Automobilista 2 | `pcars2bridge.exe` | `simracing-launch-ams2` |
| Project Cars 2 | `pcars2bridge.exe` | `simracing-launch-pcars2` |
| rFactor 2 | `rf2bridge.exe` | `simracing-launch-rf2` |
| LeMans Ultimate | `rf2bridge.exe` | `simracing-launch-lmu` |
| Euro Truck Sim 2 | none | `simracing-launch-ets2` |
| American Truck Sim | none | `simracing-launch-ats` |
| BeamNG | none | `simracing-launch-beamng` |

## Troubleshooting

### Serial device not found

```bash
ls /dev/serial/by-id/ | grep -i base
groups | grep dialout
```

### simd doesn't detect the game

```bash
# Check shared memory files
ls /dev/shm/

# For AC/ACC: acpmf_physics, acpmf_graphics, acpmf_static
# For AMS2/PC2: $pcars2$
# Verify bridge is running (for games that need it)
ps aux | grep bridge.exe
```

### monocoque shows 0 RPM

1. Verify `simd` output shows the game was detected
2. Check the game has shared memory enabled (AMS2 needs this in settings)
3. Verify `SIMAPI.DAT` exists: `ls -la /dev/shm/SIMAPI.DAT`

### Updating monocoque

```bash
distrobox enter simracing -- yay -Syu --noconfirm
```

## Credits

- [monocoque](https://github.com/Spacefreak18/monocoque) by Spacefreak18
- [simapi](https://github.com/Spacefreak18/simapi) / simd by Spacefreak18
- [simshmbridge](https://github.com/Spacefreak18/simshmbridge) by Spacefreak18
