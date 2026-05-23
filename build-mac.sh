#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build-mac.sh only supports macOS." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CORES_WORKDIR="${CORES_WORKDIR:-$REPO_ROOT/workdir}"
LIBRETRO_SUPER_SRC_DIR="${LIBRETRO_SUPER_SRC_DIR:-$CORES_WORKDIR/src/libretro-super}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/macos}"
CORES_OUTPUT_DIR="${CORES_OUTPUT_DIR:-$OUTPUT_DIR/cores}"
INFO_OUTPUT_DIR="${INFO_OUTPUT_DIR:-$OUTPUT_DIR/info}"
LIBRETRO_ARCH="${LIBRETRO_ARCH:-$(uname -m)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
NOUNIVERSAL="${NOUNIVERSAL:-1}"

list_supported_cores() {
    find "$REPO_ROOT/.github/workflows" -maxdepth 1 -type f -name 'build-*.yml' \
        ! -name 'build-all*.yml' \
        ! -name 'build-docker.yml' \
        -exec basename {} .yml \; |
        sed 's/^build-//' |
        sort -u
}

print_usage() {
    cat <<EOF
Usage:
  ./build-mac.sh --list
  ./build-mac.sh --all
  ./build-mac.sh <core> [<core> ...]

Builds workflow-defined Cores-spruce libretro cores for macOS and stages:
  $CORES_OUTPUT_DIR
  $INFO_OUTPUT_DIR
EOF
}

core_is_supported() {
    local core="$1"
    list_supported_cores | grep -Fx "$core" >/dev/null 2>&1
}

apply_core_patch() {
    local core="$1"
    local core_dir="$LIBRETRO_SUPER_SRC_DIR/libretro-$core"
    local patch_path="$REPO_ROOT/patches/macos/$core.patch"

    if [[ ! -f "$patch_path" ]]; then
        return 0
    fi

    if [[ ! -d "$core_dir/.git" ]]; then
        echo "Expected fetched core checkout at $core_dir before applying $patch_path" >&2
        return 1
    fi

    if git -C "$core_dir" apply --reverse --check "$patch_path" >/dev/null 2>&1; then
        return 0
    fi

    git -C "$core_dir" apply "$patch_path"
}

copy_matching_info_files() {
    local stamp_file="$1"

    while IFS= read -r dylib_path; do
        local dylib_name info_name
        dylib_name="$(basename "$dylib_path")"
        info_name="${dylib_name%.dylib}.info"

        if [[ -f "$LIBRETRO_SUPER_SRC_DIR/dist/info/$info_name" ]]; then
            cp "$LIBRETRO_SUPER_SRC_DIR/dist/info/$info_name" "$INFO_OUTPUT_DIR/$info_name"
        fi
    done < <(find "$CORES_OUTPUT_DIR" -maxdepth 1 -type f -name '*_libretro.dylib' -newer "$stamp_file" | sort)
}

build_one_core() {
    local core="$1"
    local stamp_file
    stamp_file="$(mktemp)"
    trap 'rm -f "$stamp_file"' RETURN

    echo
    echo "=== Building $core for macOS ==="
    touch "$stamp_file"

    (
        cd "$LIBRETRO_SUPER_SRC_DIR"
        platform=osx ARCH="$LIBRETRO_ARCH" NOUNIVERSAL="$NOUNIVERSAL" ./libretro-fetch.sh "$core"
        apply_core_patch "$core"
        platform=osx ARCH="$LIBRETRO_ARCH" NOUNIVERSAL="$NOUNIVERSAL" \
            RARCH_DIST_DIR="$CORES_OUTPUT_DIR" JOBS="$JOBS" ./libretro-build.sh "$core"
    )

    if ! find "$CORES_OUTPUT_DIR" -maxdepth 1 -type f -name '*_libretro.dylib' -newer "$stamp_file" | grep -q .; then
        echo "Build for $core finished without staging any new dylib into $CORES_OUTPUT_DIR" >&2
        return 1
    fi

    copy_matching_info_files "$stamp_file" || true

    echo "Staged cores:"
    find "$CORES_OUTPUT_DIR" -maxdepth 1 -type f -name '*_libretro.dylib' -newer "$stamp_file" -exec basename {} \; | sort | sed 's/^/  - /'
}

if [[ $# -eq 0 ]]; then
    print_usage >&2
    exit 1
fi

declare -a requested_cores=()
list_only=0
build_all=0

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            print_usage
            exit 0
            ;;
        --list)
            list_only=1
            ;;
        --all)
            build_all=1
            ;;
        *)
            requested_cores+=("$arg")
            ;;
    esac
done

if [[ "$list_only" -eq 1 ]]; then
    if [[ "$build_all" -eq 1 || ${#requested_cores[@]} -gt 0 ]]; then
        echo "--list cannot be combined with build targets." >&2
        exit 1
    fi
    list_supported_cores
    exit 0
fi

if [[ "$build_all" -eq 1 && ${#requested_cores[@]} -gt 0 ]]; then
    echo "--all cannot be combined with explicit core names." >&2
    exit 1
fi

if [[ "$build_all" -eq 1 ]]; then
    while IFS= read -r core; do
        requested_cores+=("$core")
    done < <(list_supported_cores)
fi

"$REPO_ROOT/bootstrap-mac.sh"
"$REPO_ROOT/fetch-libretro-super.sh"

mkdir -p "$CORES_OUTPUT_DIR" "$INFO_OUTPUT_DIR"

for core in "${requested_cores[@]}"; do
    if ! core_is_supported "$core"; then
        echo "Unsupported core: $core" >&2
        echo "Use ./build-mac.sh --list to see workflow-defined cores." >&2
        exit 1
    fi
done

echo
echo "=== macOS core build ==="
echo "libretro-super: $LIBRETRO_SUPER_SRC_DIR"
echo "Arch:           $LIBRETRO_ARCH"
echo "Jobs:           $JOBS"
echo "Core output:    $CORES_OUTPUT_DIR"
echo "Info output:    $INFO_OUTPUT_DIR"

declare -a failed_cores=()

for core in "${requested_cores[@]}"; do
    if ! build_one_core "$core"; then
        failed_cores+=("$core")
    fi
done

echo
echo "=== Build summary ==="
echo "Built cores: $(find "$CORES_OUTPUT_DIR" -maxdepth 1 -type f -name '*_libretro.dylib' | wc -l | tr -d ' ')"
echo "Info files:  $(find "$INFO_OUTPUT_DIR" -maxdepth 1 -type f -name '*.info' | wc -l | tr -d ' ')"

if [[ ${#failed_cores[@]} -gt 0 ]]; then
    echo "Failed cores: ${failed_cores[*]}" >&2
    exit 1
fi
