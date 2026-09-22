# FlyCast Fast UMRK PGO profile contract

`flycast_fast_umrk` is the additional MLP1 Dreamcast choice: the April 2022
Flycast source with the three renderer performance patches, MLP1 AArch64 tuning,
LTO and a frozen profile-guided optimization dataset. This directory owns that
dataset's contract.

## Files

| File | Role |
| --- | --- |
| `manifest.json` | frozen contract: source commit, patched-source identity, managed patch and recipe hashes, toolchain image, canonical paths, phase flags, exclusions, required profile shape, the twenty requested settings, the training contract and the training record |
| `profiles.tar.gz` | flat gzip/tar archive of the trained GCC `.gcda` files, created by the freeze command; absent until training is frozen |

`manifest.json` starts as `"status": "pending-training"`. The normal build lane
refuses to compile this core until a frozen dataset exists, so `--stock-parity`
reports it as a cache miss until training has been frozen.

## Contract

- Source: `https://github.com/flyinghead/flycast` at
  `4c293f306bc16a265c2d768af5d0cea138426054` plus
  `patches/mlp1/flycast_fast_umrk.patch`.
- Patched-source identity: SHA-256 of the full-index binary diff of the clean
  checkout with the managed patch applied. Untracked non-ignored files are
  rejected, so the identity cannot drift silently. Recompute it with
  `python3 scripts/mlp1-flycast-fast-umrk-profile.py tree-identity --source-dir <checkout>`.
- Recipe input: SHA-256 over `scripts/mlp1-flycast-fast-umrk-recipe.sh`, which
  owns the generation/use recipe and flags. Editing this recipe invalidates
  the contract; unrelated shared-builder edits don't. Re-record the contract
  and retrain when the applied source or effective flags change.
- Toolchain: the retrievable OCI digest
  `sha256:66aac16fb8b07e663c9b4d66970f272df195a6eba98dfad8286eabbaa617faf9`
  (`aarch64-buildroot-linux-gnu-gcc` 12.3.0). The 2026-09-22 experiment used a
  local-only image whose digest cannot be pulled, so that digest is deliberately
  not pinned. A different toolchain is a new profile contract requiring fresh
  training.
- Canonical paths: `/workspace/workdir/src/flycast-fast-umrk` and
  `/workspace/workdir/pgo/flycast-fast-umrk`. GCC's mangled `.gcda` names encode
  the object path, so both phases run in the builder container with these paths.
  The old experiment trained under `/src/src`; those counters are not a build
  input and are never imported.
- Phases: `generate` uses `-fprofile-generate=<profile dir>`; `use` uses
  `-fprofile-use=<profile dir> -fprofile-correction -fprofile-partial-training`.
  There is no blanket `-Wno-missing-profile`: excluded units carry no profile
  flag at all, other untrained units keep their warnings visible, and the build
  fails when the renderer's profile data is missing or mismatched.
- Excluded units: `core/rec-ARM64/`, `core/hw/sh4/dyna/`, `core/hw/mem/`,
  `core/hw/arm7/` and `core/libretro/vmem_utils.o`, driven by `NOPROF_FILTER`.
  Hand-written `.S` compiles keep the driver flag because gcov never instruments
  assembly.
- Profile shape: flat `.gcda` basenames at the profile root, at least 50 files,
  at least 7 matching `*#core#rend#*.gcda`, and no build products, ROMs, BIOS
  images, savestates or VMU data.

## Training

1. Build the instrumented core once:

   ```sh
   TOOLCHAIN_REPO=/path/to/mlp1-toolchain \
   ./build-mlp1.sh --flycast-fast-umrk-profile-gen
   ```

2. Train on the device with the owned command. It pauses the launcher, sets
   performance governors, installs the twenty-setting template at RetroArch's
   per-core options path, runs both contracted games for 90 seconds each from
   their savestates with a device-side input runner, quits RetroArch cleanly so
   libgcov flushes, pulls the `.gcda` tree and freezes this directory:

   ```sh
   ADB_SERIAL=<serial> scripts/mlp1-flycast-fast-umrk-train.sh \
       --core output/mlp1/profile-gen/flycast_fast_umrk_gen_libretro.so \
       --options-file '<FlyCast Fast UMRK.opt>' \
       --rom crazy-taxi=<CrazyTaxi.gdi> --state crazy-taxi=<ct.state> --input crazy-taxi=<ct.input> \
       --rom sa2=<sa2.gdi>            --state sa2=<sa2.state>      --input sa2=<sa2.input> \
       --runner crazy-taxi='<device input command>' --runner sa2='<device input command>' \
       --base-config <device retroarch.cfg> \
       --launcher-stop '<pause command>' --launcher-start '<resume command>' \
       --toolchain-id sha256:66aac16fb8b07e663c9b4d66970f272df195a6eba98dfad8286eabbaa617faf9 \
       --qualification '<what was observed>'
   ```

   Game data stays private: every path is an argument, a `device:` prefix uses an
   image already on the device, and the exit trap restores the launcher, the
   governors and any pre-existing options file.

3. Freeze (or re-freeze) from an already pulled tree:

   ```sh
   python3 scripts/mlp1-flycast-fast-umrk-profile.py freeze \
       --profile-dir profiles/mlp1/flycast_fast_umrk \
       --lock config/mlp1-core-lock.json \
       --patch patches/mlp1/flycast_fast_umrk.patch \
       --toolchain-id sha256:66aac16fb8b07e663c9b4d66970f272df195a6eba98dfad8286eabbaa617faf9 \
       --canonical-source-dir /workspace/workdir/src/flycast-fast-umrk \
       --canonical-profile-dir /workspace/workdir/pgo/flycast-fast-umrk \
       --source-dir workdir/src/flycast-fast-umrk \
       --gcda-dir <pulled .gcda tree> --options-file <FlyCast Fast UMRK.opt> \
       --game crazy-taxi --game sa2 --seconds-per-game 90 \
       --state crazy-taxi=<sha256> --state sa2=<sha256> \
       --input crazy-taxi=<sha256> --input sa2=<sha256> \
       --generation-core-sha256 <sha256 of the generation core> \
       --device <adb serial> --qualification '<record>'
   ```

   Freeze refuses a stale contract (patch, recipe input, toolchain, canonical
   paths, patched-source identity), the wrong games or duration, an options file
   that is not exactly the twenty requested settings, missing or malformed
   state/input hashes, an empty device or qualification record, and an archive
   without the required renderer profiles.

## Normal builds

The host automatically selects the manifest's immutable `toolchain.image_ref`
for both generation and use builds, pulls it if needed, and verifies its actual
image ID. `TOOLCHAIN_IMAGE` applies only to other cores. Mixed builds and
`--stock-parity` run Fast in its pinned container before building other cores
with the generic toolchain; they combine the results in one report. Cache checks
use Fast's pinned toolchain identity independently of the generic image.

`./build-mlp1.sh --stock-parity` (or `flycast_fast_umrk` by name) verifies the
contract, unpacks the archive into `workdir/pgo/flycast-fast-umrk`, builds with
`-fprofile-use`, audits the captured compile commands, strips the core and
checks that no gcov runtime or instrumentation symbols remain. A missing, empty,
corrupt or mismatched profile fails the lane with an actionable message instead
of staging a partial artifact.
