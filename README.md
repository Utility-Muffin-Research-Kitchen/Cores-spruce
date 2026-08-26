# Cores-spruce

UMRK's libretro core builder forked from the spruceOS core build lane. The
inherited workflows still target spruceOS handheld devices, and this workspace
adds local macOS and MLP1 build paths using
[libretro-super](https://github.com/libretro/libretro-super) plus a few
repo-owned special builders.

## Supported devices

| Arch | Devices |
|------|---------|
| arm64 | Trimui Brick, Smart Pro, Smart Pro S, Miyoo Flip |
| armhf | Miyoo Mini/Mini+, Miyoo A30 |

## How it works

- Two Docker images (cached on the `toolchains` release) provide cross-compilation environments
- Each core has its own GitHub Actions workflow — trigger individually or use **Build All Cores** to build everything in parallel
- Output: one zip per core containing `cores/` (armhf), `cores64/` (arm64), and a `.info` metadata file
- Built cores are uploaded to the `beta-{branch}` release

## Usage

1. **Build Docker images** (only needed once, or after Dockerfile changes): run `Build Docker Images`
2. **Build one core**: run `Build <corename>` from Actions
3. **Build all cores**: run `Build All Cores` from Actions

## macOS local builds

This fork also has a **host-side macOS build lane** for compiling the same
core set as `.dylib` libretro cores for RetroArch on Mac.

Quick start:

```sh
./bootstrap-mac.sh
./build-mac.sh gambatte mgba
```

Useful commands:

```sh
./build-mac.sh --list   # list workflow-defined supported cores
./build-mac.sh --all    # build every supported core for macOS
```

Outputs:

- cores: `output/macos/cores/*.dylib`
- info files: `output/macos/info/*.info`

### Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `LIBRETRO_SUPER_URL` | `https://github.com/libretro/libretro-super.git` | Upstream build/fetch repo |
| `LIBRETRO_SUPER_REF` | pinned commit in `fetch-libretro-super.sh` | Reproducible libretro-super checkout |
| `CORES_WORKDIR` | `./workdir` | Local ignored working area |
| `LIBRETRO_SUPER_SRC_DIR` | `./workdir/src/libretro-super` | External libretro-super checkout |
| `OUTPUT_DIR` | `./output/macos` | Final staged macOS outputs |
| `CORES_OUTPUT_DIR` | `./output/macos/cores` | Built `.dylib` cores |
| `INFO_OUTPUT_DIR` | `./output/macos/info` | Matching `.info` files |
| `LIBRETRO_ARCH` | host arch from `uname -m` | Architecture passed to libretro-super |
| `JOBS` | host CPU count | Parallel make jobs |

### Notes

- The existing GitHub Actions/Docker workflows remain the source of truth for
  spruceOS handheld targets.
- The macOS lane fetches and builds through `libretro-super`, but stages
  outputs directly into `output/macos` instead of relying on libretro-super's
  default `dist/osx-*` naming.
- Any repo-owned macOS source fixes live under `patches/macos/` and are
  applied automatically before the affected core is built.
- Some cores may still fail on macOS because their upstream build systems are
  platform-specific or currently broken outside the existing ARM Docker lanes.

## MLP1 local builds

MLP1 builds use the local `mlp1-toolchain` Docker image and stage libretro
cores directly into the SD payload shape.

Quick start:

```sh
./build-mlp1.sh                  # genesis_plus_gx vertical slice
./build-mlp1.sh --stock-parity   # all 30 stock-parity cores
./build-mlp1.sh --spruce-all     # build generic Spruce cores, report deferred
```

Useful commands:

```sh
./build-mlp1.sh --list-stock-parity
./build-mlp1.sh --list-spruce-installed
./build-mlp1.sh --list-spruce-buildable
./build-mlp1.sh --list-spruce-deferred
./build-mlp1.sh genesis_plus_gx mgba snes9x
./probe-mlp1-cores-adb.sh        # record exact runtime core names
```

The Spruce lane reads installed core names from `SPRUCE_OS_DIR` or an adjacent
`../spruceOS` checkout when available. `--spruce-buildable` builds the generic
`libretro-super` subset plus the local dedicated lanes (`fake08`, `gpsp`, and
`mgba`); `--spruce-all` builds that set and records the remaining Spruce cores
as deferred in the report.

Custom Spruce workflows still need MLP1 ports before they can join the generic
batch. Use `--list-spruce-deferred` for the current per-core reason list.

Outputs:

- cores: `output/mlp1/cores/*_libretro.so`
- info files: `output/mlp1/info/*.info`
- build report: `output/mlp1/build-report.txt`
- JSON build report: `output/mlp1/build-report.json`
- local input-fingerprint cache: `output/mlp1/core-cache.json`
- AArch64 core-info probe: `output/mlp1/tools/mlp1-core-info-probe`
- Probe-only dependency closure: `output/mlp1/tools/lib/`

`--stock-parity` includes a few repo-owned special builders, including
`easyrpg`, `fake08`, `flycast`, `gpsp`, `mame`, `mgba`, `mupen64plus_next`,
`swanstation`, and `yabasanshiro`, in addition to generic `libretro-super`
cores. The gpSP lane checks out its pinned upstream commit and builds with
`platform=arm64`, enabling the core's ARM64 dynamic recompiler.

The mGBA lane builds from its own pinned checkout with CMake. Upstream deleted
`Makefile.libretro`, so the `libretro-super` rule for this core no longer works;
because that rule's failure is not fatal, the generic lane used to re-copy the
previous build's `.so` and report it as `built`. Every stock-parity source URL,
full commit, checkout path, and recipe identity is pinned in
`config/mlp1-core-lock.json`; the build fails rather than falling back to a
branch if a pin cannot be resolved. The dedicated lanes record
`source_url`, `source_commit`, and `build_lane` in the JSON report.

The generic np2kai lane applies the repo-owned `patches/mlp1/np2kai.patch`
after fetching the core. It changes the first-run joypad mode
from `OFF` to `Arrows`, giving the handheld D-pad and buttons keyboard mappings
without preventing users from selecting np2kai's mouse or keypad modes.

The generic PUAE lanes apply their MLP1 patches so the Unix builds link their
math dependency and all Amiga firmware and support data are read from the
dedicated RetroArch system subdirectory `BIOS/puae/`. They intentionally do not
fall back to loose files in `BIOS/`. The PUAE build also brings the pinned
core-info extension list into line with the core's own `valid_extensions` by
adding its missing `raw` floppy-image entry.

Every lane's previously staged core is removed before its build runs, so a lane
that produces nothing is reported as `failed`, never as `built`. If a build
stages a binary byte-identical to the one it replaced, the text report notes it
on an `unchanged` line.

### Stock-parity cache

`--stock-parity` is incremental. A core is reused only when its locked source,
recipe identity, managed patch, libretro-super pin, toolchain image, target,
profile flags, binary checksum, and info-file checksum all match its local cache
entry. Its JSON row records `build_action` and `input_fingerprint`; the report
summary records `compiled_count` and `reused_count`.

Inspect the cache without entering the build container or compiling anything:

```sh
./build-mlp1.sh --check-stock-parity-cache
```

The one-time adoption command requires a complete local report, an immutable
reference ZIP, and that ZIP's published SHA-256. It verifies the local core
bytes against both reports and the binaries stored in the ZIP before writing
the cache:

```sh
./build-mlp1.sh --adopt-stock-parity-cache \
    --reference-zip /absolute/path/to/published-release.zip \
    --reference-sha256 <published-sha256>
```

Set `FORCE_REBUILD_CORES=1` with `--stock-parity` to bypass all hits. Explicit
core arguments always build the requested cores and update only their cache
entries. Their reports are written to `targeted-build-report.txt` and
`targeted-build-report.json`, leaving the canonical full report untouched.

Mupen64Plus-Next and YabaSanshiro apply repo-managed patches that add a
dedicated `mlp1_a55_gles3` upstream Makefile platform. Each copies its former
A53 lane's AArch64 dynarec, GLES3/EGL, linker, and assembly choices while
changing only CPU tuning to `-mcpu=cortex-a55 -mtune=cortex-a55`. Actual compile
commands are retained under `output/mlp1/logs/`. A build row becomes
`a55-contract` only after every captured compiler command contains both A55
flags, none contains an A53 override, and the core-specific graphics, dynarec,
and ARM64 assembly markers remain present.

`--spruce-all` builds the generic `libretro-super` subset and the local
dedicated lanes, then records unported Spruce cores as deferred. Use the script
for the current deferred list instead of trusting a static README copy:

```sh
./build-mlp1.sh --list-spruce-deferred
```

The text and JSON reports include `built`, `failed`, and `deferred` rows, plus
the staged core filename, info filename, ELF machine, and maximum GLIBC version
where available. JSON report version 2 also binds every built row to the
staged binary with `sha256` and reserves `library_name` for the exact,
case-sensitive value returned by the core's `retro_get_system_info()`.

An MLP1 report containing newly compiled core bytes leaves
`library_name_status` as `pending`. With the target device connected, complete
the report before packaging it:

```sh
ADB_SERIAL=optional-device-serial ./probe-mlp1-cores-adb.sh
python3 scripts/mlp1-core-report.py verify \
    --report output/mlp1/build-report.json \
    --cores-dir output/mlp1/cores
```

The runner validates every report checksum, pushes the probe, its isolated
dependency closure, and one core at a time into a private directory under
device `/tmp`, and removes that directory on success or failure. The helper
libraries exist only to let `dlopen()` resolve build-time dependencies during
the probe; they are not part of the RetroArch package. The runner updates the
report atomically only after all built rows succeed, setting
`library_name_status` to `complete` and
`library_name_count` to the number of built cores. It does not inspect or alter
the device SD card, saves, or states. Without `ADB_SERIAL`, it uses the first
online device from `adb devices`.

The manifest, apply, and verify commands validate the complete report summary:
top-level status and counts must agree with the row statuses, core IDs must be
unique, and a report with failed or deferred rows is not probeable. This does
not require a full stock-parity build; a targeted build is valid when every
requested core was built. The apply command accepts the build's internally
consistent `pending` report and changes it to `complete`; `verify` additionally
requires that complete phase, a non-empty library name for every built row, and
an unchanged checksum for every staged core.

Host checks are available without an MLP1 build or device:

```sh
make check
```
