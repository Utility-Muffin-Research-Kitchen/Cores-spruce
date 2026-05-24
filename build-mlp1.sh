#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-/Volumes/Storage/UMRK/mlp1-toolchain}"
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

usage() {
    cat <<EOF
Usage:
  ./build-mlp1.sh [core ...]
  ./build-mlp1.sh --stock-parity
  ./build-mlp1.sh --list-stock-parity

Default with no core arguments builds genesis_plus_gx for the first MLP1 slice.
Outputs:
  $CORES_OUTPUT_DIR
  $INFO_OUTPUT_DIR
  $REPORT_PATH
EOF
}

if [[ "${IN_MLP1_CONTAINER:-0}" != "1" ]]; then
    if ! docker image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
        echo "missing Docker image: $TOOLCHAIN_IMAGE" >&2
        echo "build it with: make -C $TOOLCHAIN_REPO image" >&2
        exit 1
    fi

    docker run --rm \
        -e IN_MLP1_CONTAINER=1 \
        -e LIBRETRO_SUPER_URL="${LIBRETRO_SUPER_URL:-}" \
        -e LIBRETRO_SUPER_REF="${LIBRETRO_SUPER_REF:-}" \
        -e CORES_WORKDIR=/workspace/workdir \
        -e LIBRETRO_SUPER_SRC_DIR=/workspace/workdir/src/libretro-super \
        -e OUTPUT_DIR=/workspace/output/mlp1 \
        -e CORES_OUTPUT_DIR=/workspace/output/mlp1/cores \
        -e INFO_OUTPUT_DIR=/workspace/output/mlp1/info \
        -e REPORT_PATH=/workspace/output/mlp1/build-report.txt \
        -e JOBS="${JOBS:-}" \
        -v "$REPO_ROOT":/workspace \
        -v "$TOOLCHAIN_REPO":/mlp1-toolchain:ro \
        -w /workspace \
        "$TOOLCHAIN_IMAGE" \
        /workspace/build-mlp1.sh "$@"
    exit $?
fi

JOBS="${JOBS:-$(nproc)}"

declare -a requested_cores=()
stock_parity=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --stock-parity)
            stock_parity=1
            ;;
        --list-stock-parity)
            printf '%s\n' "${STOCK_PARITY_CORES[@]}"
            exit 0
            ;;
        *)
            requested_cores+=("$1")
            ;;
    esac
    shift
done

if [[ "$stock_parity" -eq 1 && ${#requested_cores[@]} -gt 0 ]]; then
    echo "--stock-parity cannot be combined with explicit core names." >&2
    exit 1
fi

if [[ "$stock_parity" -eq 1 ]]; then
    requested_cores=("${STOCK_PARITY_CORES[@]}")
elif [[ ${#requested_cores[@]} -eq 0 ]]; then
    requested_cores=(genesis_plus_gx)
fi

"$REPO_ROOT/fetch-libretro-super.sh"

mkdir -p "$CORES_OUTPUT_DIR" "$INFO_OUTPUT_DIR" "$(dirname "$REPORT_PATH")"
: >"$REPORT_PATH"

echo "MLP1 core build"
echo "libretro-super: $LIBRETRO_SUPER_SRC_DIR"
echo "output:          $OUTPUT_DIR"
echo "jobs:            $JOBS"
echo

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

echo "MLP1 cores built under: $CORES_OUTPUT_DIR"
