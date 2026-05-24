#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-/Volumes/Storage/UMRK/mlp1-toolchain}"
SPRUCE_OS_DIR="${SPRUCE_OS_DIR:-/Volumes/Storage/GitHub/spruceOS}"
CORES_WORKDIR="${CORES_WORKDIR:-$REPO_ROOT/workdir}"
LIBRETRO_SUPER_SRC_DIR="${LIBRETRO_SUPER_SRC_DIR:-$CORES_WORKDIR/src/libretro-super}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/mlp1}"
CORES_OUTPUT_DIR="${CORES_OUTPUT_DIR:-$OUTPUT_DIR/cores}"
INFO_OUTPUT_DIR="${INFO_OUTPUT_DIR:-$OUTPUT_DIR/info}"
REPORT_PATH="${REPORT_PATH:-$OUTPUT_DIR/build-report.txt}"
JOBS="${JOBS:-}"

STOCK_PARITY_CORES=(
    2048
    mednafen_ngp
    mednafen_pce_fast
    mednafen_wswan
    dosbox_pure
    easyrpg
    fake08
    fbalpha2012
    fbneo
    fceumm
    flycast
    gambatte
    genesis_plus_gx
    gw
    handy
    mame2003_plus
    mame2010
    mame
    mgba
    mupen64plus_next
    pcsx_rearmed
    prosystem
    snes9x
    stella2014
    swanstation
    yabasanshiro
)

SPRUCE_INSTALLED_CORES_FALLBACK=(
    2048
    81
    a5200
    ardens
    arduous
    atari800
    bk
    bluemsx
    cap32
    chailove
    chimerasnes
    crocods
    daphne
    dosbox_pure
    easyrpg
    ecwolf
    fake08
    fbalpha2012
    fbneo
    fceumm
    ffmpeg
    flycast
    fmsx
    freechaf
    freeintv
    frodo
    fuse
    gambatte
    gearboy
    gearcoleco
    gearsystem
    genesis_plus_gx
    genesis_plus_gx_wide
    gme
    gpsp
    gw
    handy
    hatari
    km_duckswanstation_xtreme_amped
    km_flycast_xtreme
    km_ludicrousn64_2k22_xtreme_amped
    km_parallel_n64_xtreme_amped_turbo
    libgametank
    lowresnx
    lutro
    mame2003_plus
    mednafen_lynx
    mednafen_ngp
    mednafen_pce_fast
    mednafen_pcfx
    mednafen_supafaust
    mednafen_supergrafx
    mednafen_vb
    mednafen_wswan
    mgba
    mkxp-z
    mu
    mupen64plus
    mupen64plus_next
    neocd
    nestopia
    np2kai
    numero
    o2em
    opera
    parallel_n64
    pcsx_rearmed
    picodrive
    pokemini
    potator
    prboom
    prosystem
    puae2021
    puzzlescript
    px68k
    quasi88
    quicknes
    race
    reminiscence
    retro8
    sameduck
    scummvm
    snes9x
    snes9x2002
    snes9x2005
    snes9x2005_plus
    snes9x2010
    squirreljme
    stella2014
    swanstation
    tgbdual
    theodore
    tic80
    tyrquake
    uae4arm
    uw8
    uzem
    vecx
    vemulator
    vice_x64
    vice_xvic
    x1
    yabasanshiro
    yabasanshiro_a133p
    yabasanshiro_smartpros
)

SPRUCE_LIBRETRO_SUPER_CORES=(
    2048
    81
    a5200
    ardens
    arduous
    atari800
    bk
    bluemsx
    cap32
    chailove
    chimerasnes
    crocods
    daphne
    dosbox_pure
    easyrpg
    ecwolf
    fbalpha2012
    fbneo
    fceumm
    ffmpeg
    flycast
    fmsx
    freechaf
    freeintv
    frodo
    fuse
    gambatte
    gearboy
    gearcoleco
    gearsystem
    genesis_plus_gx
    genesis_plus_gx_wide
    gme
    gw
    handy
    hatari
    lowresnx
    lutro
    mame2003_plus
    mednafen_lynx
    mednafen_ngp
    mednafen_pce_fast
    mednafen_pcfx
    mednafen_supafaust
    mednafen_supergrafx
    mednafen_vb
    mednafen_wswan
    mgba
    mu
    mupen64plus_next
    neocd
    nestopia
    np2kai
    numero
    o2em
    opera
    parallel_n64
    pcsx_rearmed
    picodrive
    pokemini
    potator
    prboom
    prosystem
    puae2021
    puzzlescript
    px68k
    quasi88
    quicknes
    race
    reminiscence
    retro8
    sameduck
    snes9x
    snes9x2002
    snes9x2005
    snes9x2005_plus
    snes9x2010
    squirreljme
    stella2014
    swanstation
    tgbdual
    theodore
    tic80
    tyrquake
    uae4arm
    uw8
    uzem
    vecx
    vemulator
    vice_x64
    vice_xvic
    x1
    yabasanshiro
)

usage() {
    cat <<EOF
Usage:
  ./build-mlp1.sh [core ...]
  ./build-mlp1.sh --stock-parity
  ./build-mlp1.sh --spruce-all
  ./build-mlp1.sh --spruce-buildable
  ./build-mlp1.sh --list-stock-parity
  ./build-mlp1.sh --list-spruce-installed
  ./build-mlp1.sh --list-spruce-buildable
  ./build-mlp1.sh --list-spruce-deferred

Default with no core arguments builds genesis_plus_gx for the first MLP1 slice.
Outputs:
  $CORES_OUTPUT_DIR
  $INFO_OUTPUT_DIR
  $REPORT_PATH
EOF
}

print_array() {
    printf '%s\n' "$@"
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

spruce_installed_cores() {
    local retroarch_dir="$SPRUCE_OS_DIR/RetroArch/.retroarch"
    local core_dirs=()

    if [[ -d "$retroarch_dir/cores" ]]; then
        core_dirs+=("$retroarch_dir/cores")
    fi
    if [[ -d "$retroarch_dir/cores64" ]]; then
        core_dirs+=("$retroarch_dir/cores64")
    fi

    if [[ ${#core_dirs[@]} -gt 0 ]]; then
        find "${core_dirs[@]}" -maxdepth 1 -type f -name '*_libretro.so' -print \
            | sed 's#.*/##; s/_libretro\.so$//' \
            | sort -u
        return
    fi

    print_array "${SPRUCE_INSTALLED_CORES_FALLBACK[@]}"
}

spruce_buildable_cores() {
    local core
    while IFS= read -r core; do
        if array_contains "$core" "${SPRUCE_LIBRETRO_SUPER_CORES[@]}"; then
            printf '%s\n' "$core"
        fi
    done < <(spruce_installed_cores)
}

spruce_deferred_reason() {
    case "$1" in
        fake08|gpsp|km_duckswanstation_xtreme_amped|km_parallel_n64_xtreme_amped_turbo|libgametank)
            printf 'custom Cores-spruce workflow exists, MLP1 local builder not ported yet'
            ;;
        *)
            printf 'no generic libretro-super build lane in Cores-spruce'
            ;;
    esac
}

spruce_deferred_cores() {
    local core
    while IFS= read -r core; do
        if ! array_contains "$core" "${SPRUCE_LIBRETRO_SUPER_CORES[@]}"; then
            printf '%s\n' "$core"
        fi
    done < <(spruce_installed_cores)
}

print_spruce_deferred_report() {
    local core
    while IFS= read -r core; do
        printf '%s\t%s\n' "$core" "$(spruce_deferred_reason "$core")"
    done < <(spruce_deferred_cores)
}

for arg in "$@"; do
    case "$arg" in
        --list-stock-parity)
            print_array "${STOCK_PARITY_CORES[@]}"
            exit 0
            ;;
        --list-spruce-installed|--list-spruce-all)
            spruce_installed_cores
            exit 0
            ;;
        --list-spruce-buildable)
            spruce_buildable_cores
            exit 0
            ;;
        --list-spruce-deferred)
            print_spruce_deferred_report
            exit 0
            ;;
    esac
done

if [[ "${IN_MLP1_CONTAINER:-0}" != "1" ]]; then
    if ! docker image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
        echo "missing Docker image: $TOOLCHAIN_IMAGE" >&2
        echo "build it with: make -C $TOOLCHAIN_REPO image" >&2
        exit 1
    fi

    docker_args=(
        --rm
        -e IN_MLP1_CONTAINER=1
        -e LIBRETRO_SUPER_URL="${LIBRETRO_SUPER_URL:-}"
        -e LIBRETRO_SUPER_REF="${LIBRETRO_SUPER_REF:-}"
        -e CORES_WORKDIR=/workspace/workdir
        -e LIBRETRO_SUPER_SRC_DIR=/workspace/workdir/src/libretro-super
        -e OUTPUT_DIR=/workspace/output/mlp1
        -e CORES_OUTPUT_DIR=/workspace/output/mlp1/cores
        -e INFO_OUTPUT_DIR=/workspace/output/mlp1/info
        -e REPORT_PATH=/workspace/output/mlp1/build-report.txt
        -e JOBS="${JOBS:-}"
        -v "$REPO_ROOT":/workspace
        -v "$TOOLCHAIN_REPO":/mlp1-toolchain:ro
        -w /workspace
    )

    if [[ -d "$SPRUCE_OS_DIR" ]]; then
        docker_args+=(-e SPRUCE_OS_DIR=/spruceOS -v "$SPRUCE_OS_DIR":/spruceOS:ro)
    else
        docker_args+=(-e SPRUCE_OS_DIR="$SPRUCE_OS_DIR")
    fi

    docker run "${docker_args[@]}" "$TOOLCHAIN_IMAGE" /workspace/build-mlp1.sh "$@"
    exit $?
fi

JOBS="${JOBS:-$(nproc)}"

declare -a requested_cores=()
declare -a deferred_cores=()
build_mode=explicit

set_build_mode() {
    local mode="$1"
    if [[ "$build_mode" != "explicit" && "$build_mode" != "$mode" ]]; then
        echo "build modes cannot be combined." >&2
        exit 1
    fi
    build_mode="$mode"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --stock-parity)
            set_build_mode stock-parity
            ;;
        --spruce-all|--spruce-installed)
            set_build_mode spruce-all
            ;;
        --spruce-buildable)
            set_build_mode spruce-buildable
            ;;
        --list-stock-parity|--list-spruce-installed|--list-spruce-all|--list-spruce-buildable|--list-spruce-deferred)
            case "$1" in
                --list-stock-parity)
                    print_array "${STOCK_PARITY_CORES[@]}"
                    ;;
                --list-spruce-installed|--list-spruce-all)
                    spruce_installed_cores
                    ;;
                --list-spruce-buildable)
                    spruce_buildable_cores
                    ;;
                --list-spruce-deferred)
                    print_spruce_deferred_report
                    ;;
            esac
            exit 0
            ;;
        *)
            requested_cores+=("$1")
            ;;
    esac
    shift
done

if [[ "$build_mode" != "explicit" && ${#requested_cores[@]} -gt 0 ]]; then
    echo "$build_mode cannot be combined with explicit core names." >&2
    exit 1
fi

case "$build_mode" in
    stock-parity)
        requested_cores=("${STOCK_PARITY_CORES[@]}")
        ;;
    spruce-all)
        while IFS= read -r core; do
            requested_cores+=("$core")
        done < <(spruce_buildable_cores)
        while IFS= read -r core; do
            deferred_cores+=("$core")
        done < <(spruce_deferred_cores)
        ;;
    spruce-buildable)
        while IFS= read -r core; do
            requested_cores+=("$core")
        done < <(spruce_buildable_cores)
        ;;
    explicit)
        if [[ ${#requested_cores[@]} -eq 0 ]]; then
            requested_cores=(genesis_plus_gx)
        fi
        ;;
esac

"$REPO_ROOT/fetch-libretro-super.sh"

mkdir -p "$CORES_OUTPUT_DIR" "$INFO_OUTPUT_DIR" "$(dirname "$REPORT_PATH")"
: >"$REPORT_PATH"

echo "MLP1 core build"
echo "libretro-super: $LIBRETRO_SUPER_SRC_DIR"
echo "output:          $OUTPUT_DIR"
echo "jobs:            $JOBS"
if [[ "$build_mode" == spruce-* ]]; then
    echo "spruceOS:        $SPRUCE_OS_DIR"
    echo "requested:       ${#requested_cores[@]}"
    echo "deferred:        ${#deferred_cores[@]}"
fi
echo

for core in "${deferred_cores[@]}"; do
    printf 'deferred %s %s\n' "$core" "$(spruce_deferred_reason "$core")" >>"$REPORT_PATH"
done

verify_core() {
    local core_path="$1"
    local readelf_bin="${READELF:-aarch64-buildroot-linux-gnu-readelf}"
    local machine max_glibc newest

    machine="$("$readelf_bin" -h "$core_path" | awk -F: '/Machine:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    if [[ "$machine" != *"AArch64"* ]]; then
        echo "unexpected core machine for $core_path: ${machine:-missing}" >&2
        return 1
    fi

    max_glibc="$("$readelf_bin" --version-info "$core_path" 2>/dev/null | awk '
        match($0, /GLIBC_[0-9]+\.[0-9]+/) {
            v = substr($0, RSTART + 6, RLENGTH - 6);
            print v;
        }' | sort -V | tail -n 1)"

    if [[ -n "${max_glibc:-}" ]]; then
        newest="$(printf '%s\n%s\n' "$max_glibc" "2.38" | sort -V | tail -n 1)"
        if [[ "$newest" != "2.38" ]]; then
            echo "core requires GLIBC_$max_glibc, newer than target GLIBC_2.38: $core_path" >&2
            return 1
        fi
    fi
}

build_one_core() {
    local core="$1"
    local stamp_file
    stamp_file="$(mktemp)"

    echo "=== Building $core for MLP1 ==="
    touch "$stamp_file"

    if (
        cd "$LIBRETRO_SUPER_SRC_DIR"
        platform=unix ARCH=aarch64 \
            HOST_CC="${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}" \
            RARCH_DIST_DIR="$CORES_OUTPUT_DIR" \
            JOBS="$JOBS" \
            ./libretro-fetch.sh "$core"
        platform=unix ARCH=aarch64 \
            HOST_CC="${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}" \
            RARCH_DIST_DIR="$CORES_OUTPUT_DIR" \
            JOBS="$JOBS" \
            ./libretro-build.sh "$core"
    ); then
        local built=0
        while IFS= read -r core_path; do
            built=1
            local core_file info_file
            core_file="$(basename "$core_path")"
            info_file="${core_file%.so}.info"
            if [[ -f "$LIBRETRO_SUPER_SRC_DIR/dist/info/$info_file" ]]; then
                cp -f "$LIBRETRO_SUPER_SRC_DIR/dist/info/$info_file" "$INFO_OUTPUT_DIR/$info_file"
            fi
            verify_core "$core_path"
            printf 'built %s %s\n' "$core" "$core_file" >>"$REPORT_PATH"
        done < <(find "$CORES_OUTPUT_DIR" -maxdepth 1 -type f -name '*_libretro.so' -newer "$stamp_file" | sort)

        rm -f "$stamp_file"
        if [[ "$built" -eq 1 ]]; then
            return 0
        fi
        printf 'failed %s no output staged\n' "$core" >>"$REPORT_PATH"
        return 1
    fi

    rm -f "$stamp_file"
    printf 'failed %s build failed\n' "$core" >>"$REPORT_PATH"
    return 1
}

declare -a failed_cores=()
for core in "${requested_cores[@]}"; do
    if ! build_one_core "$core"; then
        failed_cores+=("$core")
    fi
done

echo
echo "=== MLP1 core build report ==="
cat "$REPORT_PATH"

if [[ ${#failed_cores[@]} -gt 0 ]]; then
    echo "Failed cores: ${failed_cores[*]}" >&2
    exit 1
fi

if [[ ${#deferred_cores[@]} -gt 0 ]]; then
    echo "Deferred cores: ${deferred_cores[*]}" >&2
    exit 1
fi

echo "MLP1 cores built under: $CORES_OUTPUT_DIR"
