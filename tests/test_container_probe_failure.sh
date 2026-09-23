#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mlp1-missing-library.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/cores" "$temp_dir/empty-libs"

cat >"$temp_dir/helper.c" <<'EOF'
int missing_probe_dependency(void) { return 1; }
EOF
cat >"$temp_dir/core.c" <<'EOF'
extern int missing_probe_dependency(void);
struct retro_system_info {
    const char *library_name, *library_version, *valid_extensions;
    int need_fullpath, block_extract;
};
void retro_get_system_info(struct retro_system_info *info) {
    info->library_name = missing_probe_dependency() ? "Missing Library" : "Wrong";
    info->library_version = "1";
    info->valid_extensions = "";
    info->need_fullpath = 0;
    info->block_extract = 0;
}
EOF

docker run --rm --platform linux/arm64 -v "$temp_dir:/work" "$image" bash -ec '
    aarch64-buildroot-linux-gnu-gcc -fPIC -shared -Wl,-soname,libmissing-probe.so \
        -o /work/libmissing-probe.so /work/helper.c
    aarch64-buildroot-linux-gnu-gcc -fPIC -shared -o /work/cores/missing_libretro.so \
        /work/core.c -L/work -lmissing-probe
    aarch64-buildroot-linux-gnu-readelf -d /work/cores/missing_libretro.so \
        | grep -q "Shared library: \[libmissing-probe.so\]"
'

python3 - "$temp_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
report = {
    "version": 2, "platform": "mlp1", "status": "passed",
    "requested_count": 1, "built_count": 1, "failed_count": 0,
    "deferred_count": 0, "library_name_status": "pending",
    "library_name_count": 0,
    "cores": [{
        "core": "missing", "status": "built", "core_file": "missing_libretro.so",
        "sha256": hashlib.sha256((root / "cores/missing_libretro.so").read_bytes()).hexdigest(),
        "library_name": "", "library_name_source": "",
    }],
}
(root / "build-report.json").write_text(json.dumps(report), encoding="utf-8")
PY

cp "$temp_dir/build-report.json" "$temp_dir/original.json"
if "$repo_root/probe-mlp1-cores-container.sh" \
    --report "$temp_dir/build-report.json" --cores-dir "$temp_dir/cores" \
    --probe "$repo_root/output/mlp1/tools/mlp1-core-info-probe" \
    --probe-libs "$temp_dir/empty-libs" >"$temp_dir/stdout" 2>"$temp_dir/stderr"; then
    echo "missing dependency unexpectedly passed" >&2
    exit 1
fi
grep -q 'missing: container probe failed' "$temp_dir/stderr"
grep -q 'libmissing-probe.so' "$temp_dir/stderr"
cmp "$temp_dir/original.json" "$temp_dir/build-report.json"
echo "missing library identifies the core and preserves the pending report"
