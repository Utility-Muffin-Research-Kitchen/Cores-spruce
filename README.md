# Cores-spruce

Build bot for libretro cores targeting spruceOS handheld devices. Builds 32-bit (armhf) and 64-bit (arm64) cores using [libretro-super](https://github.com/libretro/libretro-super).

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
cd /Volumes/Storage/UMRK/Cores-spruce
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

## TODO: cores not yet buildable

These cores are shipped by spruceOS but can't be built from libretro-super and need custom build processes:

- [ ] **mkxp-z** — hyphen in name breaks libretro-super's bash variable parsing
- [ ] **mupen64plus** — removed from libretro-super (replaced by mupen64plus_next)
- [ ] **km_flycast_xtreme** — KMFDManic/morpheuscast_xtreme fork uses bare `as` for ARM64 assembly, not cross-compile friendly
- [ ] **km_ludicrousn64_2k22_xtreme_amped** — KMFDManic fork has broken aarch64 dynarec source and missing includes
