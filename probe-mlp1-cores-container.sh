#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/mlp1}"
CORES_OUTPUT_DIR="${CORES_OUTPUT_DIR:-$OUTPUT_DIR/cores}"
REPORT_JSON_PATH="${REPORT_JSON_PATH:-$OUTPUT_DIR/build-report.json}"
CORE_INFO_PROBE_PATH="${CORE_INFO_PROBE_PATH:-$OUTPUT_DIR/tools/mlp1-core-info-probe}"
CORE_INFO_PROBE_LIBRARY_DIR="${CORE_INFO_PROBE_LIBRARY_DIR:-$(dirname "$CORE_INFO_PROBE_PATH")/lib}"
TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) REPORT_JSON_PATH="$2"; shift 2 ;;
        --cores-dir) CORES_OUTPUT_DIR="$2"; shift 2 ;;
        --probe) CORE_INFO_PROBE_PATH="$2"; shift 2 ;;
        --probe-libs) CORE_INFO_PROBE_LIBRARY_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--report PATH] [--cores-dir PATH] [--probe PATH] [--probe-libs PATH]"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for command in docker python3; do
    command -v "$command" >/dev/null 2>&1 || { echo "missing required command: $command" >&2; exit 1; }
done
[[ -f "$REPORT_JSON_PATH" ]] || { echo "missing build report: $REPORT_JSON_PATH" >&2; exit 1; }
[[ -d "$CORES_OUTPUT_DIR" ]] || { echo "missing cores directory: $CORES_OUTPUT_DIR" >&2; exit 1; }
[[ -f "$CORE_INFO_PROBE_PATH" ]] || { echo "missing AArch64 probe: $CORE_INFO_PROBE_PATH" >&2; exit 1; }
REPORT_JSON_PATH="$(cd "$(dirname "$REPORT_JSON_PATH")" && pwd -P)/$(basename "$REPORT_JSON_PATH")"
CORES_OUTPUT_DIR="$(cd "$CORES_OUTPUT_DIR" && pwd -P)"
CORE_INFO_PROBE_PATH="$(cd "$(dirname "$CORE_INFO_PROBE_PATH")" && pwd -P)/$(basename "$CORE_INFO_PROBE_PATH")"
if [[ -d "$CORE_INFO_PROBE_LIBRARY_DIR" ]]; then
    CORE_INFO_PROBE_LIBRARY_DIR="$(cd "$CORE_INFO_PROBE_LIBRARY_DIR" && pwd -P)"
fi
docker image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1 || {
    echo "missing toolchain image: $TOOLCHAIN_IMAGE" >&2; exit 1;
}

case "$(uname -m)" in
    arm64|aarch64|x86_64|amd64) ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac
if ! docker run --rm --platform linux/arm64 "$TOOLCHAIN_IMAGE" /bin/true >/dev/null 2>&1; then
    echo "cannot run linux/arm64 containers; configure qemu/binfmt on amd64 hosts" >&2
    exit 1
fi

host_tmp="$(mktemp -d "${TMPDIR:-/tmp}/umrk-mlp1-core-container-probe.XXXXXX")"
trap 'rm -rf "$host_tmp"' EXIT
python3 "$REPO_ROOT/scripts/mlp1-core-report.py" manifest \
    --report "$REPORT_JSON_PATH" --cores-dir "$CORES_OUTPUT_DIR" >"$host_tmp/manifest.tsv"
: >"$host_tmp/results.tsv"

docker_args=(--rm --platform linux/arm64
    -v "$REPO_ROOT:/workspace:ro"
    -v "$CORES_OUTPUT_DIR:/probe-cores:ro"
    -v "$CORE_INFO_PROBE_PATH:/probe-bin:ro"
    -v "$host_tmp:/probe-results")
if [[ -d "$CORE_INFO_PROBE_LIBRARY_DIR" ]]; then
    docker_args+=(-v "$CORE_INFO_PROBE_LIBRARY_DIR:/probe-libs:ro")
fi
docker run "${docker_args[@]}" "$TOOLCHAIN_IMAGE" \
    bash /workspace/scripts/probe-mlp1-cores-in-container.sh

python3 "$REPO_ROOT/scripts/mlp1-core-report.py" apply \
    --report "$REPORT_JSON_PATH" --cores-dir "$CORES_OUTPUT_DIR" \
    --results "$host_tmp/results.tsv" --source container
python3 "$REPO_ROOT/scripts/mlp1-core-report.py" verify \
    --report "$REPORT_JSON_PATH" --cores-dir "$CORES_OUTPUT_DIR"
