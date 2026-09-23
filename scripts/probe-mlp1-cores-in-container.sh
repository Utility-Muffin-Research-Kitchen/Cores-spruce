#!/usr/bin/env bash
set -euo pipefail

sysroot="${SYSROOT:?SYSROOT is required}"
loader="$sysroot/lib/ld-linux-aarch64.so.1"
[[ -x "$loader" ]] || { echo "missing Buildroot loader: $loader" >&2; exit 1; }
library_path="$sysroot/lib:$sysroot/usr/lib:/probe-libs"

while IFS=$'\t' read -r core core_file checksum; do
    [[ -n "$core" && -n "$checksum" && "$core_file" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "invalid core manifest row: $core $core_file" >&2; exit 1;
    }
    if ! library_name="$("$loader" --library-path "$library_path" \
        /probe-bin "/probe-cores/$core_file" 2> /probe-results/probe.stderr)"; then
        echo "$core: container probe failed for $core_file" >&2
        sed -n '1,20p' /probe-results/probe.stderr >&2
        exit 1
    fi
    if [[ -z "$library_name" || "$library_name" == *$'\n'* || "$library_name" == *$'\t'* ]]; then
        echo "$core: invalid library_name from container probe" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$core" "$core_file" "$checksum" "$library_name" \
        >>/probe-results/results.tsv
    echo "Probed $core: $library_name"
done </probe-results/manifest.tsv
