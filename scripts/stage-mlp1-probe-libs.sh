#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 OUTPUT_DIR CORE_LIBRETRO_SO [CORE_LIBRETRO_SO ...]" >&2
    exit 2
fi

output_dir="$1"
shift
sysroot="${SYSROOT:?SYSROOT is required}"
readelf_bin="${READELF:-aarch64-buildroot-linux-gnu-readelf}"

if [[ "$output_dir" != /* || "$output_dir" == "/" ]]; then
    echo "probe library output must be a non-root absolute path: $output_dir" >&2
    exit 1
fi

system_libraries=(
    ld-linux-aarch64.so.1
    libc.so.6
    libdl.so.2
    libEGL.so.1
    libgcc_s.so.1
    libGLESv2.so.2
    libm.so.6
    libpthread.so.0
    libresolv.so.2
    librt.so.1
    libstdc++.so.6
    libz.so.1
)

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

needed_libraries() {
    "$readelf_bin" -d "$1" 2>/dev/null \
        | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'
}

find_sysroot_library() {
    local soname="$1"
    find "$sysroot/lib" "$sysroot/usr/lib" \
        \( -type f -o -type l \) -name "$soname" -print -quit 2>/dev/null
}

mkdir -p "$output_dir"
find "$output_dir" -mindepth 1 -maxdepth 1 \
    \( -type f -o -type l \) -delete

queue=("$@")
seen=()
queue_index=0
while [[ "$queue_index" -lt "${#queue[@]}" ]]; do
    binary="${queue[$queue_index]}"
    queue_index=$((queue_index + 1))
    if [[ ! -f "$binary" ]]; then
        echo "probe dependency input is missing: $binary" >&2
        exit 1
    fi

    while IFS= read -r soname; do
        if [[ -z "$soname" ]] \
            || array_contains "$soname" "${system_libraries[@]}" \
            || array_contains "$soname" "${seen[@]}"; then
            continue
        fi
        if [[ "$soname" == */* || "$soname" == "." || "$soname" == ".." ]]; then
            echo "unsafe DT_NEEDED entry in $binary: $soname" >&2
            exit 1
        fi

        source_path="$(find_sysroot_library "$soname")"
        if [[ -z "$source_path" ]]; then
            echo "cannot resolve $soname from the MLP1 sysroot (needed by $binary)" >&2
            exit 1
        fi
        cp -fL "$source_path" "$output_dir/$soname"
        seen+=("$soname")
        queue+=("$output_dir/$soname")
    done < <(needed_libraries "$binary")
done

printf 'Staged %d non-system probe libraries in %s\n' "${#seen[@]}" "$output_dir"
