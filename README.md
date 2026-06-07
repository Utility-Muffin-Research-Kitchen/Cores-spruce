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
./build-mlp1.sh --stock-parity   # all 26 stock-parity cores
./build-mlp1.sh --spruce-all     # build generic Spruce cores, report deferred
```

Useful commands:

```sh
./build-mlp1.sh --list-stock-parity
./build-mlp1.sh --list-spruce-installed
./build-mlp1.sh --list-spruce-buildable
./build-mlp1.sh --list-spruce-deferred
./build-mlp1.sh genesis_plus_gx mgba snes9x
```

The Spruce lane reads installed core names from `SPRUCE_OS_DIR` or an adjacent
`../spruceOS` checkout when available. `--spruce-buildable` only builds the generic
`libretro-super` subset; `--spruce-all` builds that subset and records the
remaining Spruce cores as deferred in the report.

Custom Spruce workflows still need MLP1 ports before they can join the generic
batch. Use `--list-spruce-deferred` for the current per-core reason list.

Outputs:

- cores: `output/mlp1/cores/*_libretro.so`
- info files: `output/mlp1/info/*.info`
- build report: `output/mlp1/build-report.txt`
- JSON build report: `output/mlp1/build-report.json`

`--stock-parity` includes a few repo-owned special builders, including
`easyrpg`, `fake08`, `flycast`, `mame`, `mupen64plus_next`, `swanstation`, and
`yabasanshiro`, in addition to generic `libretro-super` cores.

`--spruce-all` is intentionally stricter: it builds the generic
`libretro-super` subset and records non-generic Spruce cores as deferred. Use
the script for the current deferred list instead of trusting a static README
copy:

```sh
./build-mlp1.sh --list-spruce-deferred
```

If a core appears in that deferred report but also has a stock-parity special
builder, the deferred status applies only to the generic Spruce batch.

The text and JSON reports include `built`, `failed`, and `deferred` rows, plus
the staged core filename, info filename, ELF machine, and maximum GLIBC version
where available.
