#!/usr/bin/env bash
# Dedicated Fast recipe. Keep effective PGO inputs here, apart from orchestration.
# FlyCast Fast UMRK: the April 2022 Flycast lane.
#
# It builds from the pinned old root Makefile lane instead of the current
# Flycast CMake lane, and its normal build consumes the frozen PGO dataset that
# profiles/mlp1/flycast_fast_umrk/manifest.json describes. The generation
# (maintainer training) and use phases share these canonical container paths
# and never share an object tree.
FLYCAST_FAST_UMRK_PGO_DIR="$CORES_WORKDIR/pgo/flycast-fast-umrk"
FLYCAST_FAST_UMRK_PROFILE_DIR="$REPO_ROOT/profiles/mlp1/flycast_fast_umrk"
FLYCAST_FAST_UMRK_PATCH="$REPO_ROOT/patches/mlp1/flycast_fast_umrk.patch"
FLYCAST_FAST_UMRK_INFO_DIR="$REPO_ROOT/info/mlp1"
FLYCAST_FAST_UMRK_GIT_VERSION=" 4c293f3"
FLYCAST_FAST_UMRK_COMMON_FLAGS="-flto=auto -ffat-lto-objects -fuse-linker-plugin -fno-plt -fno-semantic-interposition -fvisibility=hidden -fomit-frame-pointer -fno-stack-protector -U_FORTIFY_SOURCE -fno-math-errno -fno-trapping-math"
FLYCAST_FAST_UMRK_LDFLAGS_EXTRA="-Wl,-O1,--as-needed,--gc-sections,--hash-style=gnu"
# Space-separated patterns for make's filter-out: the ARM64 dynarec, the SH4
# block cache, fastmem/VMEM, the ARM7 core and libretro/vmem_utils.o keep their
# register assumptions intact because gcov instrumentation changes them.
FLYCAST_FAST_UMRK_NOPROF_FILTER="-fprofile-generate -fprofile-generate=% -pg -fprofile-use -fprofile-use=%"

# FlyCast Fast UMRK: the April 2022 Flycast lane.
#
# Phase "use" builds the shipped core from the frozen PGO dataset; phase
# "generate" builds the instrumented training core. Both phases run the same
# recipe so the object paths baked into GCC's mangled .gcda names stay
# identical, and the object tree is cleaned between them.
flycast_fast_umrk_profile_flags() {
    case "$1" in
        use)
            printf '%s' "-fprofile-use=$FLYCAST_FAST_UMRK_PGO_DIR -fprofile-correction -fprofile-partial-training"
            ;;
        generate)
            printf '%s' "-fprofile-generate=$FLYCAST_FAST_UMRK_PGO_DIR"
            ;;
        *)
            echo "unknown flycast_fast_umrk phase: $1" >&2
            return 1
            ;;
    esac
}

# Prove from the captured compile commands that the renderer was profiled,
# that the whole build used the requested phase, and that the assembly
# sensitive units were left out of the instrumentation.
flycast_fast_umrk_audit_compile_log() {
    local phase="$1"
    local compile_log="$2"
    local active_flag="-fprofile-use=$FLYCAST_FAST_UMRK_PGO_DIR"
    local inactive_token="-fprofile-generate"
    if [[ "$phase" == "generate" ]]; then
        active_flag="-fprofile-generate=$FLYCAST_FAST_UMRK_PGO_DIR"
        inactive_token="-fprofile-use"
    fi

    verify_a55_compile_log flycast_fast_umrk "$compile_log" || return 1

    if grep -q -- "-fopenmp" "$compile_log"; then
        echo "flycast_fast_umrk compile commands enable OpenMP" >&2
        return 1
    fi

    # The excluded C/C++ units keep the flags make filtered out of them, so the
    # contract is "every non-excluded C/C++ compile carries the phase flag, and
    # no excluded C/C++ compile carries either phase flag". Hand-written
    # assembly (.S) is counted separately: the driver leaves the phase flag on
    # that command line because ASFLAGS expands CFLAGS, but gcov never
    # instruments assembly, so the register pressure the exclusions protect
    # against cannot appear there.
    local audit compile_count active_count missing_active excluded_profiled
    local excluded_count inactive_count renderer_count asm_count asm_profiled
    audit="$(awk -v active="$active_flag" -v inactive="$inactive_token" '
        BEGIN {
            n = split("core/rec-ARM64/ core/hw/sh4/dyna/ core/hw/mem/ core/hw/arm7/ core/libretro/vmem_utils.o", patterns, " ")
        }
        /(^|\/)aarch64-buildroot-linux-gnu-(gcc|g\+\+) / && /(^| )-c( |$)/ && / -o [^ ]*\.o( |$)/ {
            compile++
            profiled = index($0, active) > 0
            if ($0 ~ /\.(S|s) -o /) {
                asm_count++
                if (profiled)
                    asm_profiled++
                next
            }
            is_excluded = 0
            for (i = 1; i <= n; i++)
                if (index($0, patterns[i]) > 0)
                    is_excluded = 1
            if (is_excluded) {
                excluded++
                if (profiled || index($0, inactive) > 0 || index($0, " -pg ") > 0)
                    excluded_profiled++
            } else {
                if (profiled)
                    active_count++
                else
                    missing_active++
                if (index($0, inactive) > 0 || index($0, " -pg ") > 0)
                    inactive_count++
            }
            if (profiled && index($0, "core/rend/gles/gles.cpp") > 0)
                renderer_count++
        }
        END {
            print compile + 0, active_count + 0, missing_active + 0, excluded_profiled + 0,
                excluded + 0, inactive_count + 0, renderer_count + 0, asm_count + 0, asm_profiled + 0
        }
    ' "$compile_log")"
    read -r compile_count active_count missing_active excluded_profiled \
        excluded_count inactive_count renderer_count asm_count asm_profiled <<<"$audit"

    if [[ "$compile_count" -le 0 ]]; then
        echo "flycast_fast_umrk captured no compile commands in $compile_log" >&2
        return 1
    fi
    if [[ "$missing_active" -ne 0 ]]; then
        echo "flycast_fast_umrk left $missing_active/$compile_count non-excluded compile commands without $active_flag" >&2
        return 1
    fi
    if [[ "$inactive_count" -ne 0 ]]; then
        echo "flycast_fast_umrk $phase build contains the other PGO phase's instrumentation in $inactive_count commands" >&2
        return 1
    fi
    if [[ "$excluded_count" -le 0 ]]; then
        echo "flycast_fast_umrk excluded no assembly-sensitive units from $phase" >&2
        return 1
    fi
    if [[ "$excluded_profiled" -ne 0 ]]; then
        echo "flycast_fast_umrk instrumented $excluded_profiled/$excluded_count assembly-sensitive excluded units" >&2
        return 1
    fi
    if [[ "$renderer_count" -le 0 ]]; then
        echo "flycast_fast_umrk renderer profiling is missing: core/rend/gles/gles.cpp was not compiled with $active_flag" >&2
        return 1
    fi
    if [[ "$asm_count" -le 0 ]]; then
        echo "flycast_fast_umrk captured no assembly compiles, so the dynarec build is not proven" >&2
        return 1
    fi

    if [[ "$phase" == "use" ]]; then
        # Missing-profile noise for units training never reached is expected and
        # is left visible in the log. Missing or mismatched *renderer* profile
        # data is not: the whole point of the dataset is those units.
        local renderer_gap
        renderer_gap="$(grep -Ei "missing|mismatch|not found|corrupt" "$compile_log" \
            | grep -E "#core#rend#|core/rend/" || true)"
        if [[ -n "$renderer_gap" ]]; then
            echo "flycast_fast_umrk consumed incomplete renderer profile data:" >&2
            printf '%s\n' "$renderer_gap" | head -n 5 >&2
            return 1
        fi
    fi
}

flycast_fast_umrk_verify_binary() {
    local core_path="$1"
    local readelf_bin="${READELF:-aarch64-buildroot-linux-gnu-readelf}"

    if "$readelf_bin" -d "$core_path" 2>/dev/null | grep -q "libgcov"; then
        echo "flycast_fast_umrk links the gcov runtime: $core_path" >&2
        return 1
    fi
    if "$readelf_bin" --dyn-syms "$core_path" 2>/dev/null | grep -q "__gcov_"; then
        echo "flycast_fast_umrk exports gcov instrumentation symbols: $core_path" >&2
        return 1
    fi
    if "$readelf_bin" -s "$core_path" 2>/dev/null | grep -q "__gcov_"; then
        echo "flycast_fast_umrk retains gcov instrumentation symbols: $core_path" >&2
        return 1
    fi
}

# Shared PGO build for both phases. "use" requires the frozen dataset; the
# maintainer-only "generate" phase produces the instrumented training core.
flycast_fast_umrk_build() {
    local phase="$1"
    local dest_dir="$2"
    local dest_name="$3"
    local src_dir="$CORES_WORKDIR/src/flycast-fast-umrk"
    local pgo_dir="$FLYCAST_FAST_UMRK_PGO_DIR"
    local compile_log="$OUTPUT_DIR/logs/flycast_fast_umrk-$phase-compile.log"
    local make_bin profile_flags
    make_bin="$(make_tool)"
    profile_flags="$(flycast_fast_umrk_profile_flags "$phase")" || return 1

    prepare_locked_core flycast_fast_umrk || return 1
    apply_mlp1_core_patch flycast_fast_umrk "$src_dir" || return 1
    mkdir -p "$(dirname "$compile_log")" "$dest_dir"

    rm -rf "$pgo_dir"
    if [[ "$phase" == "use" ]]; then
        # The dataset is verified against the lock, managed patch, toolchain
        # and canonical paths before a single object file is produced.
        python3 "$MLP1_PROFILE_TOOL" extract \
            --profile-dir "$FLYCAST_FAST_UMRK_PROFILE_DIR" \
            --lock "$MLP1_CORE_LOCK" \
            --patch "$FLYCAST_FAST_UMRK_PATCH" \
            --toolchain-id "$MLP1_TOOLCHAIN_ID" \
            --canonical-source-dir "$src_dir" \
            --canonical-profile-dir "$pgo_dir" \
            --source-dir "$src_dir" \
            --dest "$pgo_dir" || return 1
    else
        # Refuse a training build against the wrong patch, toolchain or
        # canonical path: its counters could never be consumed.
        python3 "$MLP1_PROFILE_TOOL" check \
            --profile-dir "$FLYCAST_FAST_UMRK_PROFILE_DIR" \
            --lock "$MLP1_CORE_LOCK" \
            --patch "$FLYCAST_FAST_UMRK_PATCH" \
            --toolchain-id "$MLP1_TOOLCHAIN_ID" \
            --canonical-source-dir "$src_dir" \
            --canonical-profile-dir "$pgo_dir" \
            --source-dir "$src_dir" || return 1
        mkdir -p "$pgo_dir"
    fi

    (
        cd "$src_dir" || exit 1
        # Generation and use never share an object tree.
        "$make_bin" platform=mlp1 clean >/dev/null 2>&1 || true
        "$make_bin" -j"$JOBS" platform=mlp1 \
            WITH_DYNAREC=arm64 HAVE_GENERIC_JIT=0 FORCE_GLES=1 DEBUG=0 V=1 MFLAGS= \
            GIT_VERSION="$FLYCAST_FAST_UMRK_GIT_VERSION" \
            MLP1_OPT=-O2 MLP1_TUNE="-mcpu=cortex-a55 -mtune=cortex-a55" \
            MLP1_EXTRA_CFLAGS="$FLYCAST_FAST_UMRK_COMMON_FLAGS $profile_flags" \
            MLP1_EXTRA_LDFLAGS="$FLYCAST_FAST_UMRK_COMMON_FLAGS $profile_flags $FLYCAST_FAST_UMRK_LDFLAGS_EXTRA" \
            NOPROF_FILTER="$FLYCAST_FAST_UMRK_NOPROF_FILTER" \
            AR="$(cross_prefix)-gcc-ar" \
            NM="$(cross_prefix)-gcc-nm" \
            2>&1 | tee "$compile_log" || exit 1
        flycast_fast_umrk_audit_compile_log "$phase" "$compile_log" || exit 1
        "$(cross_prefix)-strip" -s flycast_libretro.so || exit 1
        flycast_fast_umrk_verify_binary flycast_libretro.so || exit 1
        cp -f flycast_libretro.so "$dest_dir/$dest_name" || exit 1
    ) || return 1
}

build_flycast_fast_umrk_core() {
    flycast_fast_umrk_build use "$CORES_OUTPUT_DIR" "flycast_fast_umrk_libretro.so" || return 1
    CURRENT_CORE_TUNING="a55-pgo-contract"
}

build_flycast_fast_umrk_profile_gen() {
    local dest_dir="$OUTPUT_DIR/profile-gen"
    local gen_core="$dest_dir/flycast_fast_umrk_gen_libretro.so"
    local gen_log="$OUTPUT_DIR/logs/flycast_fast_umrk-generate-compile.log"

    flycast_fast_umrk_build generate "$dest_dir" "flycast_fast_umrk_gen_libretro.so" || return 1

    {
        printf 'profile-gen core %s\n' "$gen_core"
        printf 'profile-gen sha256 %s\n' "$(core_sha256 "$gen_core")"
        printf 'profile-gen compile log %s\n' "$gen_log"
    } >>"$REPORT_PATH"
    echo
    echo "PGO generation core staged: $gen_core"
    echo "Train on the device, pull the .gcda tree, then freeze the dataset:"
    echo "  python3 $MLP1_PROFILE_TOOL freeze \\"
    echo "      --profile-dir $FLYCAST_FAST_UMRK_PROFILE_DIR \\"
    echo "      --lock $MLP1_CORE_LOCK --patch $FLYCAST_FAST_UMRK_PATCH \\"
    echo "      --toolchain-id $MLP1_TOOLCHAIN_ID \\"
    echo "      --canonical-source-dir $CORES_WORKDIR/src/flycast-fast-umrk \\"
    echo "      --canonical-profile-dir $FLYCAST_FAST_UMRK_PGO_DIR \\"
    echo "      --gcda-dir <pulled .gcda tree> --options-file <FlyCast Fast UMRK.opt> \\"
    echo "      --game crazy-taxi --game sa2 --seconds-per-game 90 \\"
    echo "      --generation-core-sha256 $(core_sha256 "$gen_core") \\"
    echo "      --device <adb serial> --qualification '<record>'"
}
