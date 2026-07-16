#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/mlp1}"
CORES_OUTPUT_DIR="${CORES_OUTPUT_DIR:-$OUTPUT_DIR/cores}"
REPORT_JSON_PATH="${REPORT_JSON_PATH:-$OUTPUT_DIR/build-report.json}"
CORE_INFO_PROBE_PATH="${CORE_INFO_PROBE_PATH:-$OUTPUT_DIR/tools/mlp1-core-info-probe}"
CORE_INFO_PROBE_LIBRARY_DIR="${CORE_INFO_PROBE_LIBRARY_DIR:-}"
REMOTE_TMP_ROOT="${REMOTE_TMP_ROOT:-/tmp}"
ADB_BIN="${ADB_BIN:-adb}"

usage() {
    cat <<EOF
Usage: ./probe-mlp1-cores-adb.sh [options]

Probe every built core in an MLP1 JSON build report and atomically populate
its exact libretro library_name values.

Options:
  --report PATH       JSON build report (default: $REPORT_JSON_PATH)
  --cores-dir PATH    staged cores directory (default: $CORES_OUTPUT_DIR)
  --probe PATH        AArch64 probe executable (default: $CORE_INFO_PROBE_PATH)
  --probe-libs PATH   optional probe dependency directory
  -h, --help          show this help

ADB_SERIAL selects a device. Without it, the first online device from
"adb devices" is used. Device files live only in a private directory under
REMOTE_TMP_ROOT (default: /tmp) and are removed on success or failure.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report)
            REPORT_JSON_PATH="$2"
            shift 2
            ;;
        --cores-dir)
            CORES_OUTPUT_DIR="$2"
            shift 2
            ;;
        --probe)
            CORE_INFO_PROBE_PATH="$2"
            shift 2
            ;;
        --probe-libs)
            CORE_INFO_PROBE_LIBRARY_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$CORE_INFO_PROBE_LIBRARY_DIR" ]]; then
    CORE_INFO_PROBE_LIBRARY_DIR="$(dirname "$CORE_INFO_PROBE_PATH")/lib"
fi

for command in "$ADB_BIN" python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "missing required command: $command" >&2
        exit 1
    fi
done

if [[ ! -f "$REPORT_JSON_PATH" ]]; then
    echo "missing build report: $REPORT_JSON_PATH" >&2
    exit 1
fi
if [[ ! -d "$CORES_OUTPUT_DIR" ]]; then
    echo "missing cores directory: $CORES_OUTPUT_DIR" >&2
    exit 1
fi
if [[ ! -x "$CORE_INFO_PROBE_PATH" ]]; then
    echo "missing AArch64 core info probe: $CORE_INFO_PROBE_PATH" >&2
    echo "run ./build-mlp1.sh to build the probe alongside the cores" >&2
    exit 1
fi
if [[ ! "$REMOTE_TMP_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "REMOTE_TMP_ROOT must be an absolute path without shell metacharacters" >&2
    exit 1
fi
if [[ "$REMOTE_TMP_ROOT" == "/" ]]; then
    echo "REMOTE_TMP_ROOT must not be the filesystem root" >&2
    exit 1
fi
REMOTE_TMP_ROOT="${REMOTE_TMP_ROOT%/}"

declare -a adb_command=("$ADB_BIN")
if [[ -n "${ADB_SERIAL:-}" ]]; then
    adb_command+=(-s "$ADB_SERIAL")
else
    device_serial="$($ADB_BIN devices | awk '$2 == "device" { print $1; exit }')"
    if [[ -z "$device_serial" ]]; then
        echo "no online ADB device found" >&2
        exit 1
    fi
    adb_command+=(-s "$device_serial")
fi

host_tmp="$(mktemp -d "${TMPDIR:-/tmp}/umrk-mlp1-core-probe.XXXXXX")"
remote_dir=""

cleanup() {
    if [[ -n "$remote_dir" ]]; then
        "${adb_command[@]}" shell "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
    fi
    rm -rf "$host_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

python3 "$REPO_ROOT/scripts/mlp1-core-report.py" manifest \
    --report "$REPORT_JSON_PATH" \
    --cores-dir "$CORES_OUTPUT_DIR" \
    >"$host_tmp/manifest.tsv"

remote_dir="$("${adb_command[@]}" shell \
    "mktemp -d '$REMOTE_TMP_ROOT/umrk-core-probe.XXXXXX'" | tr -d '\r')"
remote_prefix="$REMOTE_TMP_ROOT/umrk-core-probe."
remote_suffix="${remote_dir#"$remote_prefix"}"
if [[ "$remote_dir" != "$remote_prefix"* \
    || -z "$remote_suffix" \
    || ! "$remote_suffix" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "device returned an unexpected temporary directory: $remote_dir" >&2
    remote_dir=""
    exit 1
fi

remote_probe="$remote_dir/mlp1-core-info-probe"
"${adb_command[@]}" push "$CORE_INFO_PROBE_PATH" "$remote_probe" >/dev/null
"${adb_command[@]}" shell "chmod 700 '$remote_probe'"

remote_library_dir=""
if [[ -d "$CORE_INFO_PROBE_LIBRARY_DIR" ]]; then
    remote_library_dir="$remote_dir/lib"
    "${adb_command[@]}" shell "mkdir -p '$remote_library_dir'"
    for library_path in "$CORE_INFO_PROBE_LIBRARY_DIR"/*; do
        if [[ ! -f "$library_path" ]]; then
            continue
        fi
        library_file="$(basename "$library_path")"
        if [[ ! "$library_file" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            echo "unsafe probe library filename: $library_file" >&2
            exit 1
        fi
        "${adb_command[@]}" push "$library_path" \
            "$remote_library_dir/$library_file" >/dev/null
    done
fi

: >"$host_tmp/results.tsv"
while IFS=$'\t' read -r core core_file checksum; do
    if [[ -z "$core" || -z "$core_file" || -z "$checksum" ]]; then
        echo "invalid row in probe manifest" >&2
        exit 1
    fi
    if [[ ! "$core_file" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "$core: unsafe core filename: $core_file" >&2
        exit 1
    fi

    remote_core="$remote_dir/$core_file"
    echo "Probing $core_file"
    "${adb_command[@]}" push "$CORES_OUTPUT_DIR/$core_file" "$remote_core" \
        </dev/null >/dev/null
    remote_command="'$remote_probe' '$remote_core'"
    if [[ -n "$remote_library_dir" ]]; then
        remote_command="LD_LIBRARY_PATH='$remote_library_dir' $remote_command"
    fi
    if ! library_name="$("${adb_command[@]}" shell "$remote_command" </dev/null \
        2>"$host_tmp/probe.stderr")"; then
        echo "$core: device probe failed" >&2
        sed -n '1,20p' "$host_tmp/probe.stderr" >&2
        exit 1
    fi
    library_name="${library_name//$'\r'/}"
    if [[ -z "$library_name" || "$library_name" == *$'\n'* || "$library_name" == *$'\t'* ]]; then
        echo "$core: device returned an invalid library_name" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\n' \
        "$core" "$core_file" "$checksum" "$library_name" \
        >>"$host_tmp/results.tsv"
    "${adb_command[@]}" shell "rm -f '$remote_core'" </dev/null
done <"$host_tmp/manifest.tsv"

python3 "$REPO_ROOT/scripts/mlp1-core-report.py" apply \
    --report "$REPORT_JSON_PATH" \
    --cores-dir "$CORES_OUTPUT_DIR" \
    --results "$host_tmp/results.tsv"

echo "Updated $REPORT_JSON_PATH with exact library_name values."
