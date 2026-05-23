#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIBRETRO_SUPER_URL="${LIBRETRO_SUPER_URL:-https://github.com/libretro/libretro-super.git}"
LIBRETRO_SUPER_REF="${LIBRETRO_SUPER_REF:-b344383eb04aae786d8a9565fe2a61d940a574c0}"
CORES_WORKDIR="${CORES_WORKDIR:-$REPO_ROOT/workdir}"
LIBRETRO_SUPER_SRC_DIR="${LIBRETRO_SUPER_SRC_DIR:-$CORES_WORKDIR/src/libretro-super}"

mkdir -p "$(dirname "$LIBRETRO_SUPER_SRC_DIR")"

if [[ ! -d "$LIBRETRO_SUPER_SRC_DIR/.git" ]]; then
    git clone "$LIBRETRO_SUPER_URL" "$LIBRETRO_SUPER_SRC_DIR"
fi

git -C "$LIBRETRO_SUPER_SRC_DIR" remote set-url origin "$LIBRETRO_SUPER_URL"
git -C "$LIBRETRO_SUPER_SRC_DIR" fetch --tags --prune origin
git -C "$LIBRETRO_SUPER_SRC_DIR" -c advice.detachedHead=false checkout "$LIBRETRO_SUPER_REF"

echo "=== libretro-super ==="
echo "Source: $LIBRETRO_SUPER_SRC_DIR"
echo "Ref:    $(git -C "$LIBRETRO_SUPER_SRC_DIR" rev-parse HEAD)"
