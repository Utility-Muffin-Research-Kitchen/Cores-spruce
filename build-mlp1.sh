#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TOOLCHAIN_REPO=""
if [[ -d "$REPO_ROOT/../mlp1-toolchain" ]]; then
    DEFAULT_TOOLCHAIN_REPO="$(cd "$REPO_ROOT/../mlp1-toolchain" && pwd)"
fi
DEFAULT_SPRUCE_OS_DIR=""
if [[ -d "$REPO_ROOT/../spruceOS" ]]; then
    DEFAULT_SPRUCE_OS_DIR="$(cd "$REPO_ROOT/../spruceOS" && pwd)"
fi

TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-$DEFAULT_TOOLCHAIN_REPO}"
SPRUCE_OS_DIR="${SPRUCE_OS_DIR:-$DEFAULT_SPRUCE_OS_DIR}"
CORES_WORKDIR="${CORES_WORKDIR:-$REPO_ROOT/workdir}"
LIBRETRO_SUPER_SRC_DIR="${LIBRETRO_SUPER_SRC_DIR:-$CORES_WORKDIR/src/libretro-super}"
EASYRPG_REF="${EASYRPG_REF:-}"
FAKE08_URL="${FAKE08_URL:-https://github.com/jtothebell/fake-08.git}"
FAKE08_REF="${FAKE08_REF:-}"
GPSP_URL="${GPSP_URL:-https://github.com/libretro/gpsp.git}"
GPSP_REF="${GPSP_REF:-69e86ebe89f14c3f5f75b809c12c0a953b3d6ce4}"
MGBA_URL="${MGBA_URL:-https://github.com/libretro/mgba.git}"
MGBA_REF="${MGBA_REF:-e31759b24e7a4e3899285ff720d7b573ac328ae7}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/mlp1}"
CORES_OUTPUT_DIR="${CORES_OUTPUT_DIR:-$OUTPUT_DIR/cores}"
INFO_OUTPUT_DIR="${INFO_OUTPUT_DIR:-$OUTPUT_DIR/info}"
REPORT_PATH="${REPORT_PATH:-$OUTPUT_DIR/build-report.txt}"
REPORT_JSON_PATH="${REPORT_JSON_PATH:-${REPORT_PATH%.txt}.json}"
CORE_INFO_PROBE_PATH="${CORE_INFO_PROBE_PATH:-$OUTPUT_DIR/tools/mlp1-core-info-probe}"
CORE_INFO_PROBE_LIBRARY_DIR="${CORE_INFO_PROBE_LIBRARY_DIR:-$OUTPUT_DIR/tools/lib}"
JOBS="${JOBS:-}"
MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-release}"

STOCK_PARITY_CORES=(
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
    gpsp
    mupen64plus_next
    np2kai
    pcsx_rearmed
    picodrive
    prosystem
    snes9x
    stella2014
    swanstation
    yabasanshiro
)

# These core ids have a local dedicated build lane. They are buildable when
# requested through the Spruce inventory, but must not be treated as generic
# libretro-super builds.
MLP1_CUSTOM_SPRUCE_CORES=(
    fake08
    gpsp
    mgba
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
  $REPORT_JSON_PATH
  $CORE_INFO_PROBE_PATH
  $CORE_INFO_PROBE_LIBRARY_DIR
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
    if [[ -z "$SPRUCE_OS_DIR" ]]; then
        print_array "${SPRUCE_INSTALLED_CORES_FALLBACK[@]}"
        return
    fi

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
        if array_contains "$core" "${SPRUCE_LIBRETRO_SUPER_CORES[@]}" \
            || array_contains "$core" "${MLP1_CUSTOM_SPRUCE_CORES[@]}"; then
            printf '%s\n' "$core"
        fi
    done < <(spruce_installed_cores)
}

spruce_deferred_reason() {
    case "$1" in
        km_duckswanstation_xtreme_amped|km_parallel_n64_xtreme_amped_turbo|libgametank)
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
        if ! array_contains "$core" "${SPRUCE_LIBRETRO_SUPER_CORES[@]}" \
            && ! array_contains "$core" "${MLP1_CUSTOM_SPRUCE_CORES[@]}"; then
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
    if [[ -z "$TOOLCHAIN_REPO" ]]; then
        echo "TOOLCHAIN_REPO is required when ../mlp1-toolchain is not present." >&2
        exit 1
    fi
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
        -e GPSP_URL="$GPSP_URL"
        -e GPSP_REF="$GPSP_REF"
        -e MGBA_URL="$MGBA_URL"
        -e MGBA_REF="$MGBA_REF"
        -e CORES_WORKDIR=/workspace/workdir
        -e LIBRETRO_SUPER_SRC_DIR=/workspace/workdir/src/libretro-super
        -e OUTPUT_DIR=/workspace/output/mlp1
        -e CORES_OUTPUT_DIR=/workspace/output/mlp1/cores
        -e INFO_OUTPUT_DIR=/workspace/output/mlp1/info
        -e REPORT_PATH=/workspace/output/mlp1/build-report.txt
        -e REPORT_JSON_PATH=/workspace/output/mlp1/build-report.json
        -e CORE_INFO_PROBE_PATH=/workspace/output/mlp1/tools/mlp1-core-info-probe
        -e CORE_INFO_PROBE_LIBRARY_DIR=/workspace/output/mlp1/tools/lib
        -e JOBS="${JOBS:-}"
        -e MLP1_BUILD_PROFILE="$MLP1_BUILD_PROFILE"
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

if [[ -f /opt/mlp1-toolchain/umrk/mlp1-build-flags.env ]]; then
    . /opt/mlp1-toolchain/umrk/mlp1-build-flags.env
elif [[ -f /mlp1-toolchain/flags/mlp1-build-flags.env ]]; then
    . /mlp1-toolchain/flags/mlp1-build-flags.env
else
    UMRK_MLP1_TARGET_SOC="rk3566"
    UMRK_MLP1_TARGET_CPU="cortex-a55"
    UMRK_MLP1_PROFILE_CFLAGS="-O2 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_CXXFLAGS="-O2 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_LDFLAGS="-Wl,--gc-sections"
fi

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
LIBRETRO_SUPER_RESOLVED_URL="$(git -C "$LIBRETRO_SUPER_SRC_DIR" remote get-url origin)"
LIBRETRO_SUPER_RESOLVED_COMMIT="$(git -C "$LIBRETRO_SUPER_SRC_DIR" rev-parse HEAD)"

mkdir -p "$CORES_OUTPUT_DIR" "$INFO_OUTPUT_DIR" "$(dirname "$REPORT_PATH")"
: >"$REPORT_PATH"
mkdir -p "$(dirname "$REPORT_JSON_PATH")"

declare -a REPORT_ROWS=()
REPORT_SEP=$'\x1f'

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

report_add_row() {
    local core="$1"
    local status="$2"
    local core_file="${3:-}"
    local info_file="${4:-}"
    local reason="${5:-}"
    local machine="${6:-}"
    local max_glibc="${7:-}"
    local tuning="${8:-}"
    local source_url="${9:-}"
    local source_commit="${10:-}"
    local build_lane="${11:-}"
    local sha256="${12:-}"
    local library_name="${13:-}"

    REPORT_ROWS+=("$core$REPORT_SEP$status$REPORT_SEP$core_file$REPORT_SEP$info_file$REPORT_SEP$reason$REPORT_SEP$machine$REPORT_SEP$max_glibc$REPORT_SEP$tuning$REPORT_SEP$source_url$REPORT_SEP$source_commit$REPORT_SEP$build_lane$REPORT_SEP$sha256$REPORT_SEP$library_name")
}

write_json_report() {
    local failed_count="${1:-0}"
    local deferred_count="${2:-0}"
    local status="passed"
    if [[ "$failed_count" -gt 0 || "$deferred_count" -gt 0 ]]; then
        status="failed"
    fi

    local built_count=0
    local row row_status
    for row in "${REPORT_ROWS[@]}"; do
        IFS="$REPORT_SEP" read -r _ row_status _ <<<"$row"
        if [[ "$row_status" == "built" ]]; then
            built_count=$((built_count + 1))
        fi
    done
    local library_name_status="not-applicable"
    if [[ "$built_count" -gt 0 ]]; then
        library_name_status="pending"
    fi

    {
        printf '{\n'
        printf '  "version": 2,\n'
        printf '  "platform": "mlp1",\n'
        printf '  "build_mode": "%s",\n' "$(json_escape "$build_mode")"
        printf '  "target_soc": "%s",\n' "$(json_escape "$UMRK_MLP1_TARGET_SOC")"
        printf '  "target_cpu": "%s",\n' "$(json_escape "$UMRK_MLP1_TARGET_CPU")"
        printf '  "build_profile": "%s",\n' "$(json_escape "$MLP1_BUILD_PROFILE")"
        printf '  "cflags": "%s",\n' "$(json_escape "$UMRK_MLP1_PROFILE_CFLAGS")"
        printf '  "cxxflags": "%s",\n' "$(json_escape "$UMRK_MLP1_PROFILE_CXXFLAGS")"
        printf '  "ldflags": "%s",\n' "$(json_escape "$UMRK_MLP1_PROFILE_LDFLAGS")"
        printf '  "libretro_super_url": "%s",\n' "$(json_escape "$LIBRETRO_SUPER_RESOLVED_URL")"
        printf '  "libretro_super_commit": "%s",\n' "$(json_escape "$LIBRETRO_SUPER_RESOLVED_COMMIT")"
        printf '  "status": "%s",\n' "$status"
        printf '  "requested_count": %d,\n' "${#requested_cores[@]}"
        printf '  "built_count": %d,\n' "$built_count"
        printf '  "failed_count": %d,\n' "$failed_count"
        printf '  "deferred_count": %d,\n' "$deferred_count"
        printf '  "library_name_status": "%s",\n' "$library_name_status"
        printf '  "library_name_count": 0,\n'
        printf '  "output_dir": "%s",\n' "$(json_escape "$OUTPUT_DIR")"
        printf '  "cores_output_dir": "%s",\n' "$(json_escape "$CORES_OUTPUT_DIR")"
        printf '  "info_output_dir": "%s",\n' "$(json_escape "$INFO_OUTPUT_DIR")"
        printf '  "text_report": "%s",\n' "$(json_escape "$REPORT_PATH")"
        printf '  "cores": [\n'
        local index=0
        for row in "${REPORT_ROWS[@]}"; do
            IFS="$REPORT_SEP" read -r core row_status core_file info_file reason machine max_glibc tuning source_url source_commit build_lane sha256 library_name <<<"$row"
            if [[ "$index" -gt 0 ]]; then
                printf ',\n'
            fi
            printf '    {\n'
            printf '      "core": "%s",\n' "$(json_escape "$core")"
            printf '      "status": "%s",\n' "$(json_escape "$row_status")"
            printf '      "core_file": "%s",\n' "$(json_escape "$core_file")"
            printf '      "info_file": "%s",\n' "$(json_escape "$info_file")"
            printf '      "reason": "%s",\n' "$(json_escape "$reason")"
            printf '      "machine": "%s",\n' "$(json_escape "$machine")"
            printf '      "max_glibc": "%s",\n' "$(json_escape "$max_glibc")"
            printf '      "tuning": "%s",\n' "$(json_escape "$tuning")"
            printf '      "source_url": "%s",\n' "$(json_escape "$source_url")"
            printf '      "source_commit": "%s",\n' "$(json_escape "$source_commit")"
            printf '      "build_lane": "%s",\n' "$(json_escape "$build_lane")"
            printf '      "sha256": "%s",\n' "$(json_escape "$sha256")"
            printf '      "library_name": "%s"\n' "$(json_escape "$library_name")"
            printf '    }'
            index=$((index + 1))
        done
        printf '\n'
        printf '  ]\n'
        printf '}\n'
    } >"$REPORT_JSON_PATH"
}

echo "MLP1 core build"
echo "libretro-super: $LIBRETRO_SUPER_SRC_DIR"
echo "output:          $OUTPUT_DIR"
echo "json report:     $REPORT_JSON_PATH"
echo "core info probe: $CORE_INFO_PROBE_PATH"
echo "jobs:            $JOBS"
if [[ "$build_mode" == spruce-* ]]; then
    echo "spruceOS:        $SPRUCE_OS_DIR"
    echo "requested:       ${#requested_cores[@]}"
    echo "deferred:        ${#deferred_cores[@]}"
fi
echo

for core in "${deferred_cores[@]}"; do
    reason="$(spruce_deferred_reason "$core")"
    printf 'deferred %s %s\n' "$core" "$reason" >>"$REPORT_PATH"
    report_add_row "$core" "deferred" "" "" "$reason" "" "" "not-built"
done

core_machine() {
    local core_path="$1"
    local readelf_bin="${READELF:-aarch64-buildroot-linux-gnu-readelf}"
    "$readelf_bin" -h "$core_path" | awk -F: '/Machine:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
}

core_max_glibc() {
    local core_path="$1"
    local readelf_bin="${READELF:-aarch64-buildroot-linux-gnu-readelf}"
    "$readelf_bin" --version-info "$core_path" 2>/dev/null | awk '
        match($0, /GLIBC_[0-9]+\.[0-9]+/) {
            v = substr($0, RSTART + 6, RLENGTH - 6);
            print v;
        }' | sort -V | tail -n 1
}

core_sha256() {
    local core_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$core_path" | awk '{print $1}'
    else
        shasum -a 256 "$core_path" | awk '{print $1}'
    fi
}

verify_core() {
    local core_path="$1"
    local machine max_glibc newest

    machine="$(core_machine "$core_path")"
    if [[ "$machine" != *"AArch64"* ]]; then
        echo "unexpected core machine for $core_path: ${machine:-missing}" >&2
        return 1
    fi

    max_glibc="$(core_max_glibc "$core_path")"

    if [[ -n "${max_glibc:-}" ]]; then
        newest="$(printf '%s\n%s\n' "$max_glibc" "2.38" | sort -V | tail -n 1)"
        if [[ "$newest" != "2.38" ]]; then
            echo "core requires GLIBC_$max_glibc, newer than target GLIBC_2.38: $core_path" >&2
            return 1
        fi
    fi
}

build_core_info_probe() {
    local cc="${CC:-${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}-gcc}"
    local temp_path="$CORE_INFO_PROBE_PATH.tmp.$$"
    local -a profile_cflags=()
    local -a profile_ldflags=()

    read -r -a profile_cflags <<<"${UMRK_MLP1_PROFILE_CFLAGS:-}"
    read -r -a profile_ldflags <<<"${UMRK_MLP1_PROFILE_LDFLAGS:-}"
    mkdir -p "$(dirname "$CORE_INFO_PROBE_PATH")"
    rm -f "$temp_path"
    if ! "$cc" -std=c11 -Wall -Wextra -Werror \
        "${profile_cflags[@]}" \
        "$REPO_ROOT/tools/mlp1-core-info-probe.c" \
        "${profile_ldflags[@]}" -ldl -o "$temp_path"; then
        rm -f "$temp_path"
        return 1
    fi
    if ! verify_core "$temp_path"; then
        rm -f "$temp_path"
        return 1
    fi
    mv -f "$temp_path" "$CORE_INFO_PROBE_PATH"
}

stage_core_info_probe_libraries() {
    local -a core_paths=()
    local row row_status core_file

    for row in "${REPORT_ROWS[@]}"; do
        IFS="$REPORT_SEP" read -r _ row_status core_file _ <<<"$row"
        if [[ "$row_status" == "built" ]]; then
            core_paths+=("$CORES_OUTPUT_DIR/$core_file")
        fi
    done

    if [[ ${#core_paths[@]} -eq 0 ]]; then
        mkdir -p "$CORE_INFO_PROBE_LIBRARY_DIR"
        find "$CORE_INFO_PROBE_LIBRARY_DIR" -mindepth 1 -maxdepth 1 \
            \( -type f -o -type l \) -delete
        return 0
    fi

    "$REPO_ROOT/scripts/stage-mlp1-probe-libs.sh" \
        "$CORE_INFO_PROBE_LIBRARY_DIR" "${core_paths[@]}"
}

copy_core_info() {
    local info_file="$1"

    if [[ -f "$LIBRETRO_SUPER_SRC_DIR/dist/info/$info_file" ]]; then
        cp -f "$LIBRETRO_SUPER_SRC_DIR/dist/info/$info_file" "$INFO_OUTPUT_DIR/$info_file"
        return 0
    fi

    if [[ -n "$SPRUCE_OS_DIR" && -f "$SPRUCE_OS_DIR/RetroArch/.retroarch/info/$info_file" ]]; then
        cp -f "$SPRUCE_OS_DIR/RetroArch/.retroarch/info/$info_file" "$INFO_OUTPUT_DIR/$info_file"
        return 0
    fi

    if [[ -n "$SPRUCE_OS_DIR" && -f "$SPRUCE_OS_DIR/RetroArch/.retroarch/cores/$info_file" ]]; then
        cp -f "$SPRUCE_OS_DIR/RetroArch/.retroarch/cores/$info_file" "$INFO_OUTPUT_DIR/$info_file"
        return 0
    fi

    return 1
}

stage_built_cores_since() {
    local core="$1"
    local stamp_file="$2"
    local built=0

    while IFS= read -r core_path; do
        built=1
        local core_file info_file
        core_file="$(basename "$core_path")"
        info_file="${core_file%.so}.info"
        if ! copy_core_info "$info_file"; then
            printf 'failed %s matching info file missing: %s\n' "$core" "$info_file" >>"$REPORT_PATH"
            report_add_row "$core" "failed" "$core_file" "$info_file" "matching info file missing" "" "" "${CURRENT_CORE_TUNING:-unknown}" "${CURRENT_CORE_SOURCE_URL:-}" "${CURRENT_CORE_SOURCE_COMMIT:-}" "${CURRENT_CORE_BUILD_LANE:-unknown}"
            return 1
        fi
        local machine max_glibc sha256
        machine="$(core_machine "$core_path")"
        max_glibc="$(core_max_glibc "$core_path")"
        if ! verify_core "$core_path"; then
            printf 'failed %s verifier rejected %s\n' "$core" "$core_file" >>"$REPORT_PATH"
            report_add_row "$core" "failed" "$core_file" "$info_file" "verifier rejected core" "$machine" "$max_glibc" "${CURRENT_CORE_TUNING:-unknown}" "${CURRENT_CORE_SOURCE_URL:-}" "${CURRENT_CORE_SOURCE_COMMIT:-}" "${CURRENT_CORE_BUILD_LANE:-unknown}"
            return 1
        fi
        sha256="$(core_sha256 "$core_path")"
        if [[ "$core_file" == "${core}_libretro.so" \
            && -n "${CURRENT_CORE_PREVIOUS_SHA256:-}" \
            && "$sha256" == "$CURRENT_CORE_PREVIOUS_SHA256" ]]; then
            # Legitimate for a reproducible rebuild of unchanged source, but
            # also what a lane that recycles a stale binary looks like.
            printf 'unchanged %s %s %s\n' "$core" "$core_file" "$sha256" >>"$REPORT_PATH"
            echo "note: $core staged a binary identical to the previous build: $sha256" >&2
        fi
        printf 'built %s %s\n' "$core" "$core_file" >>"$REPORT_PATH"
        report_add_row "$core" "built" "$core_file" "$info_file" "" "$machine" "$max_glibc" "${CURRENT_CORE_TUNING:-unknown}" "${CURRENT_CORE_SOURCE_URL:-}" "${CURRENT_CORE_SOURCE_COMMIT:-}" "${CURRENT_CORE_BUILD_LANE:-unknown}" "$sha256" ""
    done < <(find "$CORES_OUTPUT_DIR" -maxdepth 1 -type f -name '*_libretro.so' -newer "$stamp_file" | sort)

    if [[ "$built" -eq 1 ]]; then
        return 0
    fi

    printf 'failed %s no output staged\n' "$core" >>"$REPORT_PATH"
    report_add_row "$core" "failed" "" "" "no output staged" "" "" "${CURRENT_CORE_TUNING:-unknown}" "${CURRENT_CORE_SOURCE_URL:-}" "${CURRENT_CORE_SOURCE_COMMIT:-}" "${CURRENT_CORE_BUILD_LANE:-unknown}"
    return 1
}

build_fake08_core() {
    local src_dir="$CORES_WORKDIR/src/fake-08"

    if [[ ! -d "$src_dir/.git" ]]; then
        rm -rf "$src_dir"
        git clone --depth 1 --recurse-submodules "$FAKE08_URL" "$src_dir" || return 1
    fi

    if [[ -n "$FAKE08_REF" ]]; then
        git -C "$src_dir" fetch origin "$FAKE08_REF" || true
        git -C "$src_dir" checkout "$FAKE08_REF" || return 1
    fi
    git -C "$src_dir" submodule update --init --recursive || return 1

    make -C "$src_dir/platform/libretro" \
        CC="${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}-gcc" \
        CXX="${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}-g++" \
        -j"$JOBS" || return 1
    cp -f "$src_dir/platform/libretro/fake08_libretro.so" "$CORES_OUTPUT_DIR/fake08_libretro.so" || return 1
}

build_gpsp_core() {
    local src_dir="$CORES_WORKDIR/src/gpsp"
    local resolved_commit

    if [[ ! "$GPSP_REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "GPSP_REF must be a full 40-character commit SHA: $GPSP_REF" >&2
        return 1
    fi

    mkdir -p "$(dirname "$src_dir")"
    if [[ ! -d "$src_dir/.git" ]]; then
        rm -rf "$src_dir"
        git clone "$GPSP_URL" "$src_dir" || return 1
    fi

    git -C "$src_dir" remote set-url origin "$GPSP_URL" || return 1
    git -C "$src_dir" fetch --tags --prune origin || return 1
    if ! git -C "$src_dir" cat-file -e "${GPSP_REF}^{commit}" 2>/dev/null; then
        echo "gpSP source pin is unavailable: $GPSP_REF" >&2
        return 1
    fi
    git -C "$src_dir" -c advice.detachedHead=false checkout --detach "$GPSP_REF" || return 1
    resolved_commit="$(git -C "$src_dir" rev-parse HEAD)"
    if [[ "$resolved_commit" != "$GPSP_REF" ]]; then
        echo "gpSP resolved commit differs from requested pin: $resolved_commit" >&2
        return 1
    fi
    git -C "$src_dir" clean -ffdx || return 1

    (
        cd "$src_dir" || exit 1
        make clean || exit 1
        make -j"$JOBS" platform=arm64 \
            CC="$(cross_cc)" \
            CXX="$(cross_cxx)" \
            AR="$(cross_ar)" \
            RANLIB="$(cross_ranlib)" || exit 1
        cp -f gpsp_libretro.so "$CORES_OUTPUT_DIR/gpsp_libretro.so" || exit 1
    ) || return 1

    CURRENT_CORE_SOURCE_URL="$GPSP_URL"
    CURRENT_CORE_SOURCE_COMMIT="$resolved_commit"
}

# mGBA deleted Makefile.libretro in upstream 89404771c, so libretro-super's
# make-based rule can no longer build it. Build it through CMake, from a
# dedicated checkout that the macOS lane's patches/macos/mgba.patch never
# touches.
build_mgba_core() {
    local src_dir="$CORES_WORKDIR/src/mgba"
    local build_dir="$src_dir/build"
    local resolved_commit
    local -a cmake_args=()

    if [[ ! "$MGBA_REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "MGBA_REF must be a full 40-character commit SHA: $MGBA_REF" >&2
        return 1
    fi

    mkdir -p "$(dirname "$src_dir")"
    if [[ ! -d "$src_dir/.git" ]]; then
        rm -rf "$src_dir"
        git clone "$MGBA_URL" "$src_dir" || return 1
    fi

    git -C "$src_dir" remote set-url origin "$MGBA_URL" || return 1
    git -C "$src_dir" fetch --tags --prune origin || return 1
    if ! git -C "$src_dir" cat-file -e "${MGBA_REF}^{commit}" 2>/dev/null; then
        echo "mGBA source pin is unavailable: $MGBA_REF" >&2
        return 1
    fi
    git -C "$src_dir" -c advice.detachedHead=false checkout --detach "$MGBA_REF" || return 1
    resolved_commit="$(git -C "$src_dir" rev-parse HEAD)"
    if [[ "$resolved_commit" != "$MGBA_REF" ]]; then
        echo "mGBA resolved commit differs from requested pin: $resolved_commit" >&2
        return 1
    fi
    # mGBA derives its reported version from git describe, so a tracked
    # modification would ship a core that calls itself "-dirty".
    git -C "$src_dir" reset --hard "$MGBA_REF" || return 1
    git -C "$src_dir" clean -ffdx || return 1

    cmake_args=(
        -S "$src_dir"
        -B "$build_dir"
        -DCMAKE_BUILD_TYPE=Release
        -DBUILD_LIBRETRO=ON
        -DBUILD_QT=OFF
        -DBUILD_SDL=OFF
        -DBUILD_ROM_TEST=OFF
        -DBUILD_SUITE=OFF
        -DBUILD_PYTHON=OFF
        -DUSE_DISCORD_RPC=OFF
    )
    if [[ -n "${CMAKE_TOOLCHAIN_FILE:-}" ]]; then
        cmake_args+=("-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE")
    fi

    rm -rf "$build_dir"
    CC="$(cross_cc)" CXX="$(cross_cxx)" cmake "${cmake_args[@]}" || return 1
    cmake --build "$build_dir" -j"$JOBS" || return 1
    cp -f "$build_dir/mgba_libretro.so" "$CORES_OUTPUT_DIR/mgba_libretro.so" || return 1

    CURRENT_CORE_SOURCE_URL="$MGBA_URL"
    CURRENT_CORE_SOURCE_COMMIT="$resolved_commit"
}

build_easyrpg_core() {
    local src_dir="$LIBRETRO_SUPER_SRC_DIR/libretro-easyrpg"
    local cmake_args=(
        -S .
        -B build
        -DCMAKE_BUILD_TYPE=Release
        -DPLAYER_TARGET_PLATFORM=libretro
        -DBUILD_SHARED_LIBS=ON
        -DPLAYER_BUILD_LIBLCF=ON
    )

    (
        cd "$LIBRETRO_SUPER_SRC_DIR" || exit 1
        platform=unix ARCH=aarch64 \
            HOST_CC="${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}" \
            RARCH_DIST_DIR="$CORES_OUTPUT_DIR" \
            JOBS="$JOBS" \
            ./libretro-fetch.sh easyrpg || exit 1
    ) || return 1

    if [[ -n "$EASYRPG_REF" ]]; then
        git -C "$src_dir" fetch origin "$EASYRPG_REF" || true
        git -C "$src_dir" checkout "$EASYRPG_REF" || return 1
    fi

    if [[ -n "${CMAKE_TOOLCHAIN_FILE:-}" ]]; then
        cmake_args+=("-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE")
    fi

    (
        cd "$src_dir" || exit 1
        CC="${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}-gcc" \
            CXX="${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}-g++" \
            cmake "${cmake_args[@]}" || exit 1
        cmake --build build --target easyrpg_libretro --config Release -- -j"$JOBS" || exit 1
        cp -f build/easyrpg_libretro.so "$CORES_OUTPUT_DIR/easyrpg_libretro.so" || exit 1
    )
}

cross_prefix() {
    printf '%s' "${CROSS_TRIPLE:-aarch64-buildroot-linux-gnu}"
}

cross_cc() {
    printf '%s-gcc' "$(cross_prefix)"
}

cross_cxx() {
    printf '%s-g++' "$(cross_prefix)"
}

cross_ar() {
    printf '%s-ar' "$(cross_prefix)"
}

cross_ranlib() {
    printf '%s-ranlib' "$(cross_prefix)"
}

make_tool() {
    if command -v gmake >/dev/null 2>&1; then
        printf 'gmake'
    else
        printf 'make'
    fi
}

purge_stale_core_artifacts() {
    local src_dir="$1"

    if [[ -d "$src_dir" ]]; then
        find "$src_dir" -type f -name '*_libretro.so' -delete
    fi
}

fetch_libretro_super_core() {
    local core="$1"
    local platform_name="${2:-unix}"

    (
        cd "$LIBRETRO_SUPER_SRC_DIR" || exit 1
        platform="$platform_name" ARCH=aarch64 \
            HOST_CC="$(cross_prefix)" \
            RARCH_DIST_DIR="$CORES_OUTPUT_DIR" \
            JOBS="$JOBS" \
            ./libretro-fetch.sh "$core" || exit 1
    )
}

build_flycast_core() {
    local src_dir="$LIBRETRO_SUPER_SRC_DIR/libretro-flycast"

    fetch_libretro_super_core flycast unix || return 1

    rm -rf "$src_dir/build"
    (
        cd "$src_dir" || exit 1
        CC="$(cross_cc)" CXX="$(cross_cxx)" \
            cmake -S . -B build \
                -DLIBRETRO=ON \
                -DCMAKE_POSITION_INDEPENDENT_CODE=TRUE \
                -DCMAKE_BUILD_TYPE=Release \
                -DUSE_GLES=ON || exit 1
        cmake --build build --target flycast_libretro --config Release -- -j"$JOBS" || exit 1
        cp -f build/flycast_libretro.so "$CORES_OUTPUT_DIR/flycast_libretro.so" || exit 1
    )
}

build_mame_core() {
    local src_dir="$LIBRETRO_SUPER_SRC_DIR/libretro-mame"
    local make_bin
    local mame_jobs="$JOBS"
    make_bin="$(make_tool)"
    if ((mame_jobs > 4)); then
        mame_jobs=4
    fi

    fetch_libretro_super_core mame unix || return 1

    (
        cd "$src_dir" || exit 1
        "$make_bin" -f Makefile.libretro platform=unix \
            CC="$(cross_cc)" \
            CXX="$(cross_cxx)" \
            AR="$(cross_ar)" \
            RANLIB="$(cross_ranlib)" \
            OVERRIDE_CC="$(cross_cc)" \
            OVERRIDE_CXX="$(cross_cxx)" \
            OVERRIDE_AR="$(cross_ar)" \
            clean || exit 1
        "$make_bin" -f Makefile.libretro platform=unix -j"$mame_jobs" \
            CC="$(cross_cc)" \
            CXX="$(cross_cxx)" \
            AR="$(cross_ar)" \
            RANLIB="$(cross_ranlib)" \
            OVERRIDE_CC="$(cross_cc)" \
            OVERRIDE_CXX="$(cross_cxx)" \
            OVERRIDE_AR="$(cross_ar)" || exit 1
        cp -f mame_libretro.so "$CORES_OUTPUT_DIR/mame_libretro.so" || exit 1
    )
}

build_mupen64plus_next_core() {
    local src_dir="$LIBRETRO_SUPER_SRC_DIR/libretro-mupen64plus_next"
    local make_bin
    make_bin="$(make_tool)"

    fetch_libretro_super_core mupen64plus_next arm64_cortex_a53_gles3 || return 1

    (
        cd "$src_dir" || exit 1
        "$make_bin" platform=arm64_cortex_a53_gles3 -j"$JOBS" \
            CC="$(cross_cc)" \
            CXX="$(cross_cxx)" \
            CC_AS="$(cross_cc)" \
            AR="$(cross_ar)" \
            RANLIB="$(cross_ranlib)" \
            clean || exit 1
        "$make_bin" platform=arm64_cortex_a53_gles3 -j"$JOBS" \
            CC="$(cross_cc)" \
            CXX="$(cross_cxx)" \
            CC_AS="$(cross_cc)" \
            AR="$(cross_ar)" \
            RANLIB="$(cross_ranlib)" || exit 1
        cp -f mupen64plus_next_libretro.so "$CORES_OUTPUT_DIR/mupen64plus_next_libretro.so" || exit 1
    )
}

build_swanstation_core() {
    local src_dir="$LIBRETRO_SUPER_SRC_DIR/libretro-swanstation"

    fetch_libretro_super_core swanstation unix || return 1
    rm -rf "$src_dir/build"
    build_libretro_super_core swanstation
}

build_yabasanshiro_core() {
    local src_dir="$LIBRETRO_SUPER_SRC_DIR/libretro-yabasanshiro/yabause/src/libretro"
    local make_bin
    make_bin="$(make_tool)"

    fetch_libretro_super_core yabasanshiro arm64_cortex_a53_gles3 || return 1

    (
        cd "$src_dir" || exit 1
        "$make_bin" platform=arm64_cortex_a53_gles3 -j"$JOBS" \
            CC="$(cross_cc)" \
            CXX="$(cross_cxx)" \
            AR="$(cross_ar)" \
            RANLIB="$(cross_ranlib)" \
            clean || exit 1
        "$make_bin" platform=arm64_cortex_a53_gles3 -j"$JOBS" \
            CC="$(cross_cc)" \
            CXX="$(cross_cxx)" \
            AR="$(cross_ar)" \
            RANLIB="$(cross_ranlib)" || exit 1
        cp -f yabasanshiro_libretro.so "$CORES_OUTPUT_DIR/yabasanshiro_libretro.so" || exit 1
    )
}

build_libretro_super_core() {
    local core="$1"

    fetch_libretro_super_core "$core" unix || return 1

    # libretro-super's die() has its exit commented out, so a failed compile
    # does not stop the run: libretro-build.sh goes on to copy whatever
    # *_libretro.so the checkout still holds from a previous build and counts
    # it as "successfully processed". Drop those first so a broken build
    # produces no output instead of silently re-shipping the last good one.
    purge_stale_core_artifacts "$LIBRETRO_SUPER_SRC_DIR/libretro-$core"

    (
        cd "$LIBRETRO_SUPER_SRC_DIR" || exit 1
        platform=unix ARCH=aarch64 \
            HOST_CC="$(cross_prefix)" \
            RARCH_DIST_DIR="$CORES_OUTPUT_DIR" \
            JOBS="$JOBS" \
            ./libretro-build.sh "$core" || exit 1
    )
}

# Set before dispatch so a lane that fails early still reports where it ran.
# Everything not listed here fetches and builds through libretro-super.
core_build_lane() {
    local core="$1"
    case "$core" in
        fake08)
            printf 'custom-makefile'
            ;;
        gpsp)
            printf 'custom-arm64'
            ;;
        mgba)
            printf 'custom-cmake'
            ;;
        *)
            printf 'generic-libretro-super'
            ;;
    esac
}

core_tuning_status() {
    local core="$1"
    case "$core" in
        mupen64plus_next|yabasanshiro)
            printf 'upstream-a53-platform'
            ;;
        gpsp)
            printf 'arm64-dynarec'
            ;;
        *)
            printf 'generic-aarch64'
            ;;
    esac
}

build_one_core() {
    local core="$1"
    local stamp_file
    local staged_core="$CORES_OUTPUT_DIR/${core}_libretro.so"
    stamp_file="$(mktemp)"

    echo "=== Building $core for MLP1 ==="

    # Never let a previous run's binary stand in for this one. With the staged
    # artifact gone, a lane that fails to produce a core reports "no output
    # staged" instead of inheriting whatever was already there.
    CURRENT_CORE_PREVIOUS_SHA256=""
    if [[ -f "$staged_core" ]]; then
        CURRENT_CORE_PREVIOUS_SHA256="$(core_sha256 "$staged_core")"
        rm -f "$staged_core"
    fi

    touch "$stamp_file"
    CURRENT_CORE_TUNING="$(core_tuning_status "$core")"
    CURRENT_CORE_SOURCE_URL=""
    CURRENT_CORE_SOURCE_COMMIT=""
    CURRENT_CORE_BUILD_LANE="$(core_build_lane "$core")"

    local build_status=1
    case "$core" in
        easyrpg)
            build_easyrpg_core && build_status=0
            ;;
        fake08)
            build_fake08_core && build_status=0
            ;;
        gpsp)
            build_gpsp_core && build_status=0
            ;;
        flycast)
            build_flycast_core && build_status=0
            ;;
        mame)
            build_mame_core && build_status=0
            ;;
        mgba)
            build_mgba_core && build_status=0
            ;;
        mupen64plus_next)
            build_mupen64plus_next_core && build_status=0
            ;;
        swanstation)
            build_swanstation_core && build_status=0
            ;;
        yabasanshiro)
            build_yabasanshiro_core && build_status=0
            ;;
        *)
            build_libretro_super_core "$core" && build_status=0
            ;;
    esac

    if [[ "$build_status" -eq 0 ]]; then
        if stage_built_cores_since "$core" "$stamp_file"; then
            rm -f "$stamp_file"
            return 0
        fi
        rm -f "$stamp_file"
        return 1
    fi

    rm -f "$stamp_file"
    printf 'failed %s build failed\n' "$core" >>"$REPORT_PATH"
    report_add_row "$core" "failed" "" "" "build failed" "" "" "${CURRENT_CORE_TUNING:-unknown}" "${CURRENT_CORE_SOURCE_URL:-}" "${CURRENT_CORE_SOURCE_COMMIT:-}" "${CURRENT_CORE_BUILD_LANE:-unknown}"
    return 1
}

declare -a failed_cores=()
if ! build_core_info_probe; then
    echo "Failed to build the MLP1 core info probe." >&2
    exit 1
fi
for core in "${requested_cores[@]}"; do
    if ! build_one_core "$core"; then
        failed_cores+=("$core")
    fi
done

if ! stage_core_info_probe_libraries; then
    echo "Failed to stage the MLP1 core probe dependency closure." >&2
    exit 1
fi

echo
echo "=== MLP1 core build report ==="
cat "$REPORT_PATH"
write_json_report "${#failed_cores[@]}" "${#deferred_cores[@]}"
echo "JSON report: $REPORT_JSON_PATH"

if [[ ${#failed_cores[@]} -gt 0 ]]; then
    echo "Failed cores: ${failed_cores[*]}" >&2
    exit 1
fi

if [[ ${#deferred_cores[@]} -gt 0 ]]; then
    echo "Deferred cores: ${deferred_cores[*]}" >&2
    exit 1
fi

echo "MLP1 cores built under: $CORES_OUTPUT_DIR"
