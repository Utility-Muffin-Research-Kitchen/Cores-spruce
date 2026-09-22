#!/usr/bin/env bash
# FlyCast Fast UMRK: owned MLP1 PGO training run.
#
# Stages the generation core from
# build-mlp1.sh --flycast-fast-umrk-profile-gen with the exact requested option
# template, pauses the launcher, sets performance governors, plays the
# contracted games for the contracted time from their savestates with audio
# enabled and a device-side input runner, quits RetroArch cleanly so libgcov
# flushes, pulls the .gcda tree and freezes the dataset. Every change it makes
# on the device (launcher, governors, options file, pushed data) is restored by
# the exit trap.
#
# ROM, savestate, input and runner details are private or device-specific and
# are never embedded here: pass them as arguments or environment variables.
# Nothing in this script depends on a umrk-workspace scratch directory.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_TOOL="${MLP1_PROFILE_TOOL:-$REPO_ROOT/scripts/mlp1-flycast-fast-umrk-profile.py}"
PROFILE_DIR="$REPO_ROOT/profiles/mlp1/flycast_fast_umrk"
LOCK_PATH="$REPO_ROOT/config/mlp1-core-lock.json"
PATCH_PATH="$REPO_ROOT/patches/mlp1/flycast_fast_umrk.patch"
TRAIN_CORE_NAME="flycast_fast_umrk_train_libretro.so"

CORE_PATH="${MLP1_FLYCAST_FAST_UMRK_GEN_CORE:-$REPO_ROOT/output/mlp1/profile-gen/flycast_fast_umrk_gen_libretro.so}"
OPTIONS_FILE="${MLP1_FLYCAST_FAST_UMRK_OPTIONS:-}"
PULL_DIR="${MLP1_FLYCAST_FAST_UMRK_PULL_DIR:-$REPO_ROOT/output/mlp1/profile-gen/gcda}"
# /userdata is writable persistent storage on MLP1; /tmp is RAM-backed and too
# small for commercial game images.
DEVICE_DIR="${MLP1_FLYCAST_FAST_UMRK_DEVICE_DIR:-/userdata/flycast-fast-umrk-train}"
RETROARCH_BIN="${MLP1_RETROARCH:-retroarch}"
RETROARCHCTL="${MLP1_RETROARCHCTL:-}"
BASE_CONFIG="${MLP1_RETROARCH_CONFIG:-}"
CONFIG_DIR="${MLP1_RETROARCH_CONFIG_DIR:-}"
TOOLCHAIN_ID="${MLP1_TOOLCHAIN_ID:-}"
ADB_SERIAL="${ADB_SERIAL:-}"
CANONICAL_SOURCE_DIR="${MLP1_FLYCAST_FAST_UMRK_CANONICAL_SOURCE_DIR:-/workspace/workdir/src/flycast-fast-umrk}"
CANONICAL_PROFILE_DIR="${MLP1_FLYCAST_FAST_UMRK_CANONICAL_PROFILE_DIR:-/workspace/workdir/pgo/flycast-fast-umrk}"
# Host checkout the generation build produced; used to re-verify the patched
# source identity the manifest froze.
SOURCE_DIR="${MLP1_FLYCAST_FAST_UMRK_SOURCE_DIR:-}"
SECONDS_PER_GAME="${MLP1_FLYCAST_FAST_UMRK_SECONDS:-90}"
NETCMD_PORT="${MLP1_FLYCAST_FAST_UMRK_NETCMD_PORT:-5535}"
STATE_LOG_PATTERN="${MLP1_FLYCAST_FAST_UMRK_STATE_LOG_PATTERN:-Loading state}"
QUALIFICATION="${MLP1_FLYCAST_FAST_UMRK_QUALIFICATION:-}"
LAUNCHER_STOP="${MLP1_LAUNCHER_STOP:-}"
LAUNCHER_START="${MLP1_LAUNCHER_START:-}"
SET_GOVERNORS=1
ALLOW_LAUNCHER_RUNNING=0
ALLOW_MISSING_SOURCE_CHECK=0
KEEP_DEVICE_DATA=0
FREEZE=1
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: scripts/mlp1-flycast-fast-umrk-train.sh [options]

Required (or set the matching environment variable):
  --core PATH             generation core (default: output/mlp1/profile-gen/flycast_fast_umrk_gen_libretro.so)
  --options-file PATH     the twenty-setting "FlyCast Fast UMRK.opt" template
  --rom GAME=PATH         content; a "device:/abs/path" value uses an image already on the device
  --state GAME=PATH       savestate pushed as the auto-load state for that game
  --input GAME=PATH       input/drive script for that game
  --runner GAME=COMMAND   device command that applies the input while the game runs
  --toolchain-id SHA256   toolchain image id used for the generation build
  --qualification TEXT    short record of what was observed on the device
  --base-config PATH      device retroarch.cfg (or --config-dir)

Device control:
  --config-dir DIR        device RetroArch config directory (default: dirname of --base-config)
  --launcher-stop CMD     device command that pauses the launcher stack
  --launcher-start CMD    device command that resumes it (required with --launcher-stop)
  --allow-launcher-running  explicitly accept training with the launcher still running
  --allow-missing-source-check  do not verify the patched source identity (fixtures only)
  --no-governors          do not set/restore CPU, GPU and DMC performance governors

Runner contract (per game):
  --runner-evidence GAME=PATH  device path the runner writes (default: DEVICE_DIR/GAME.frames)
  --runner-warmup SECONDS      wait before the runner starts (default: 3)
  The runner must run for the training window and append at least two lines that
  contain "frame=<number>" with a strictly increasing value. Its exit status may
  be 0 (finished by itself) or 124 (stopped by the training timeout); anything
  else fails the run.
  Placeholders available in COMMAND: %GAME% %DEVICE_DIR% %ROM% %EVIDENCE% %INPUT%

Other:
  --retroarch PATH        device RetroArch binary or name (default: retroarch)
  --retroarchctl PATH     device jawaka-retroarchctl for a clean quit
  --device-dir PATH       device scratch directory (default: /userdata/flycast-fast-umrk-train)
  --pull-dir PATH         host directory for the pulled .gcda tree
  --netcmd-port PORT      RetroArch network command port (default: 5535)
  --state-log-pattern P   log text proving the state loaded (default: "Loading state")
  --expect-log PATTERN    extra RetroArch log text to require (repeatable)
  --adb-serial SERIAL     adb device serial (default: ADB_SERIAL, else first device)
  --keep-device-data      leave pushed ROM/state/input files on the device
  --no-freeze             pull and verify the .gcda tree only
  --dry-run               print the device commands without running them
  -h, --help
EOF
}

die() {
    echo "mlp1-flycast-fast-umrk-train: $*" >&2
    exit 2
}

declare -a ROM_ARGS=()
declare -a STATE_ARGS=()
declare -a INPUT_ARGS=()
declare -a RUNNER_ARGS=()
declare -a EVIDENCE_ARGS=()
declare -a REQUIRE_LOG_PATTERNS=()
RUNNER_WARMUP=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --core) CORE_PATH="$2"; shift 2 ;;
        --options-file) OPTIONS_FILE="$2"; shift 2 ;;
        --rom) ROM_ARGS+=("$2"); shift 2 ;;
        --state) STATE_ARGS+=("$2"); shift 2 ;;
        --input) INPUT_ARGS+=("$2"); shift 2 ;;
        --runner) RUNNER_ARGS+=("$2"); shift 2 ;;
        --runner-evidence) EVIDENCE_ARGS+=("$2"); shift 2 ;;
        --runner-warmup) RUNNER_WARMUP="$2"; shift 2 ;;
        --toolchain-id) TOOLCHAIN_ID="$2"; shift 2 ;;
        --qualification) QUALIFICATION="$2"; shift 2 ;;
        --base-config) BASE_CONFIG="$2"; shift 2 ;;
        --config-dir) CONFIG_DIR="$2"; shift 2 ;;
        --launcher-stop) LAUNCHER_STOP="$2"; shift 2 ;;
        --launcher-start) LAUNCHER_START="$2"; shift 2 ;;
        --allow-launcher-running) ALLOW_LAUNCHER_RUNNING=1; shift ;;
        --allow-missing-source-check) ALLOW_MISSING_SOURCE_CHECK=1; shift ;;
        --source-dir) SOURCE_DIR="$2"; shift 2 ;;
        --no-governors) SET_GOVERNORS=0; shift ;;
        --retroarch) RETROARCH_BIN="$2"; shift 2 ;;
        --retroarchctl) RETROARCHCTL="$2"; shift 2 ;;
        --device-dir) DEVICE_DIR="$2"; shift 2 ;;
        --pull-dir) PULL_DIR="$2"; shift 2 ;;
        --netcmd-port) NETCMD_PORT="$2"; shift 2 ;;
        --state-log-pattern) STATE_LOG_PATTERN="$2"; shift 2 ;;
        --expect-log) REQUIRE_LOG_PATTERNS+=("$2"); shift 2 ;;
        --adb-serial) ADB_SERIAL="$2"; shift 2 ;;
        --keep-device-data) KEEP_DEVICE_DATA=1; shift ;;
        --no-freeze) FREEZE=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

arg_value() {
    local list_name="$1" key="$2"
    local -n list="$list_name"
    local item
    for item in "${list[@]}"; do
        if [[ "${item%%=*}" == "$key" ]]; then
            printf '%s' "${item#*=}"
            return 0
        fi
    done
    return 1
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

mapfile -t CONTRACT_GAMES < <(python3 - "$PROFILE_DIR/manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(manifest["training_contract"]["games"]))
PY
)

(( ${#CONTRACT_GAMES[@]} > 0 )) || die "the profile manifest declares no training games"
(( ${#ROM_ARGS[@]} > 0 )) || die "--rom GAME=PATH is required for every contracted game"

if [[ -z "$BASE_CONFIG" && -z "$CONFIG_DIR" ]]; then
    die "--base-config PATH or --config-dir DIR is required so RetroArch's own config is preserved"
fi
if [[ -n "$BASE_CONFIG" && -z "$CONFIG_DIR" ]]; then
    CONFIG_DIR="$(dirname "$BASE_CONFIG")"
fi
if [[ -z "$LAUNCHER_STOP" && "$ALLOW_LAUNCHER_RUNNING" != "1" ]]; then
    die "pass --launcher-stop CMD (and --launcher-start CMD) so the launcher cannot contend with the run, or --allow-launcher-running to accept the contention"
fi
if [[ -n "$LAUNCHER_STOP" && -z "$LAUNCHER_START" ]]; then
    die "--launcher-stop requires --launcher-start so the launcher is resumed afterwards"
fi

declare -a STATE_HASH_ARGS=()
declare -a INPUT_HASH_ARGS=()
declare -a GAME_ARGS=()
declare -A ROM_SPEC=()
declare -A STATE_SPEC=()
declare -A INPUT_SPEC=()
declare -A RUNNER_SPEC=()
declare -A EVIDENCE_SPEC=()

if [[ "$ALLOW_MISSING_SOURCE_CHECK" == "1" ]]; then
    SOURCE_DIR=""
elif [[ -z "$SOURCE_DIR" && -d "$REPO_ROOT/workdir/src/flycast-fast-umrk/.git" ]]; then
    SOURCE_DIR="$REPO_ROOT/workdir/src/flycast-fast-umrk"
fi

cache_pull_absent=0
for game in "${CONTRACT_GAMES[@]}"; do
    rom="$(arg_value ROM_ARGS "$game")" || die "--rom $game=PATH is required"
    state="$(arg_value STATE_ARGS "$game")" || die "--state $game=PATH is required"
    input="$(arg_value INPUT_ARGS "$game")" || die "--input $game=PATH is required"
    runner="$(arg_value RUNNER_ARGS "$game")" || die "--runner $game=COMMAND is required so the run has input"
    evidence="$(arg_value EVIDENCE_ARGS "$game" || printf '%s' "$DEVICE_DIR/$game.frames")"
    if [[ "$rom" == device:* ]]; then
        ROM_SPEC[$game]="${rom#device:}"
    else
        [[ -f "$rom" ]] || die "--rom $game does not exist: $rom"
        ROM_SPEC[$game]="$DEVICE_DIR/roms/$(basename "$rom")"
    fi
    for spec in "state:$state" "input:$input"; do
        label="${spec%%:*}"
        path="${spec#*:}"
        [[ -f "$path" ]] || die "--$label $game does not exist: $path"
    done
    STATE_SPEC[$game]="$DEVICE_DIR/savestates/$(basename "${ROM_SPEC[$game]%.*}").state.auto"
    INPUT_SPEC[$game]="$DEVICE_DIR/$game.input"
    RUNNER_SPEC[$game]="$runner"
    EVIDENCE_SPEC[$game]="$evidence"
    STATE_HASH_ARGS+=("--state" "$game=$(sha256_of "$state")")
    INPUT_HASH_ARGS+=("--input" "$game=$(sha256_of "$input")")
    GAME_ARGS+=("--game" "$game")
done

[[ -n "$OPTIONS_FILE" ]] || die "--options-file PATH is required"
[[ -f "$OPTIONS_FILE" ]] || die "options template does not exist: $OPTIONS_FILE"
[[ -n "$TOOLCHAIN_ID" ]] || die "--toolchain-id SHA256 is required"
[[ -n "$QUALIFICATION" ]] || die "--qualification TEXT is required"
[[ -f "$CORE_PATH" ]] || die "generation core does not exist: $CORE_PATH"

# The freeze step enforces the same contract; checking first avoids wasting a
# device run when the patch, toolchain or canonical paths have moved.
SOURCE_ARGS=()
if [[ -n "$SOURCE_DIR" ]]; then
    SOURCE_ARGS=(--source-dir "$SOURCE_DIR")
elif [[ "$ALLOW_MISSING_SOURCE_CHECK" == "1" ]]; then
    echo "warning: source identity check skipped (--allow-missing-source-check)" >&2
fi

python3 "$PROFILE_TOOL" check \
    --profile-dir "$PROFILE_DIR" \
    --lock "$LOCK_PATH" \
    --patch "$PATCH_PATH" \
    --toolchain-id "$TOOLCHAIN_ID" \
    --canonical-source-dir "$CANONICAL_SOURCE_DIR" \
    --canonical-profile-dir "$CANONICAL_PROFILE_DIR" \
    "${SOURCE_ARGS[@]}"

ADB=(adb)
if [[ -n "$ADB_SERIAL" ]]; then
    ADB+=(-s "$ADB_SERIAL")
fi

adb_shell() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '+ adb shell %s\n' "$1"
        return 0
    fi
    "${ADB[@]}" shell "$1"
}

adb_push() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '+ adb push %s %s\n' "$1" "$2"
        return 0
    fi
    "${ADB[@]}" push "$1" "$2" >/dev/null
}

expand_runner() {
    local template="$1" game="$2"
    local command="$template"
    command="${command//%GAME%/$game}"
    command="${command//%DEVICE_DIR%/$DEVICE_DIR}"
    command="${command//%ROM%/${ROM_SPEC[$game]}}"
    command="${command//%INPUT%/${INPUT_SPEC[$game]}}"
    command="${command//%EVIDENCE%/${EVIDENCE_SPEC[$game]}}"
    printf '%s' "$command"
}

GCOV_DIR="$DEVICE_DIR/gcda"
RA_LOG="$DEVICE_DIR/retroarch.log"
OPTIONS_BACKUP="$DEVICE_DIR/options.backup"
OVERLAY="$DEVICE_DIR/appendconfig.cfg"
STATE_DIR="$DEVICE_DIR/savestates"
GOVERNOR_SNAPSHOT="$DEVICE_DIR/governors.snapshot"
core_name="${TRAIN_CORE_NAME%_libretro.so}"
per_core_options="$CONFIG_DIR/$core_name/$core_name.opt"

launcher_stopped=0
binary_present=0

cleanup() {
    local status=$?
    set +e
    if [[ "$DRY_RUN" != "1" && "$binary_present" == "1" ]]; then
        adb_shell "for pid in \$(cat '$DEVICE_DIR'/*.runner.pid 2>/dev/null); do kill -TERM -- -\$pid 2>/dev/null; sleep 1; kill -KILL -- -\$pid 2>/dev/null; done; true" >/dev/null 2>&1
        adb_shell "for pid in \$(cat '$DEVICE_DIR'/*.pid 2>/dev/null); do kill \$pid 2>/dev/null; done; true" >/dev/null 2>&1
        adb_shell "pkill -f '$core_name' 2>/dev/null; true" >/dev/null 2>&1
        if [[ "$SET_GOVERNORS" == "1" ]]; then
            adb_shell "test -f '$GOVERNOR_SNAPSHOT' && while read -r path value; do [ -w \"\$path\" ] && echo \"\$value\" >\"\$path\"; done <'$GOVERNOR_SNAPSHOT'; true" >/dev/null 2>&1
        fi
        if adb_shell "test -f '$per_core_options.trainbak'" >/dev/null 2>&1; then
            adb_shell "cp -f '$per_core_options.trainbak' '$per_core_options'; rm -f '$per_core_options.trainbak'" >/dev/null 2>&1
        else
            adb_shell "rm -f '$per_core_options'" >/dev/null 2>&1
        fi
        if [[ "$KEEP_DEVICE_DATA" != "1" ]]; then
            adb_shell "rm -rf '$DEVICE_DIR/roms' '$STATE_DIR' '$DEVICE_DIR'/*.input; true" >/dev/null 2>&1
        fi
        if [[ "$launcher_stopped" == "1" && -n "$LAUNCHER_START" ]]; then
            adb_shell "$LAUNCHER_START" >/dev/null 2>&1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

if [[ "$DRY_RUN" != "1" ]]; then
    binary_present=1
    mkdir -p "$PULL_DIR"
fi

if [[ -n "$LAUNCHER_STOP" && "$DRY_RUN" != "1" ]]; then
    adb_shell "$LAUNCHER_STOP"
    launcher_stopped=1
elif [[ -n "$LAUNCHER_STOP" ]]; then
    printf '+ adb shell %s\n' "$LAUNCHER_STOP"
fi

adb_shell "rm -rf '$DEVICE_DIR'; mkdir -p '$DEVICE_DIR/roms' '$GCOV_DIR' '$STATE_DIR'"
adb_push "$CORE_PATH" "$DEVICE_DIR/$TRAIN_CORE_NAME"

# The option template is installed exactly where RetroArch looks for a
# per-core options file, with any existing file backed up and restored by the
# trap. global_core_options is forced off so the per-core file wins over the
# device's shared options.
adb_shell "mkdir -p '$(dirname "$per_core_options")'; if [ -f '$per_core_options' ]; then cp -f '$per_core_options' '$per_core_options.trainbak'; fi"
adb_push "$OPTIONS_FILE" "$per_core_options"

# RetroArch overlay: keep the device's own config, force the per-core options
# path we just populated (never the shared/global option file), keep audio on,
# auto-load the savestate, and open the network command port used for the clean
# quit.
overlay_file="$PULL_DIR/appendconfig.cfg"
if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$PULL_DIR"
    {
        printf 'global_core_options = "false"\n'
        printf 'savestate_directory = "%s"\n' "$STATE_DIR"
        printf 'savestate_auto_load = "true"\n'
        printf 'savestate_auto_save = "false"\n'
        printf 'config_save_on_exit = "false"\n'
        printf 'audio_enable = "true"\n'
        printf 'audio_mute_enable = "false"\n'
        printf 'network_cmd_enable = "true"\n'
        printf 'network_cmd_port = "%s"\n' "$NETCMD_PORT"
    } >"$overlay_file"
    adb_push "$overlay_file" "$OVERLAY"
else
    printf '+ write overlay %s (global_core_options=false, savestate_directory=%s, audio enabled, netcmd %s)\n' \
        "$OVERLAY" "$STATE_DIR" "$NETCMD_PORT"
    printf '+ adb push %s %s\n' "$overlay_file" "$OVERLAY"
fi

if [[ "$SET_GOVERNORS" == "1" ]]; then
    adb_shell "for path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor /sys/class/devfreq/*/governor; do [ -w \"\$path\" ] || continue; printf '%s %s\\n' \"\$path\" \"\$(cat \"\$path\")\"; done >'$GOVERNOR_SNAPSHOT'"
    adb_shell "while read -r path value; do echo performance >\"\$path\" 2>/dev/null || true; done <'$GOVERNOR_SNAPSHOT'"
fi

for game in "${CONTRACT_GAMES[@]}"; do
    rom_spec="${ROM_SPEC[$game]}"
    if [[ "$rom_spec" == "$DEVICE_DIR"/roms/* ]]; then
        adb_push "$(arg_value ROM_ARGS "$game")" "$rom_spec"
    fi
    adb_push "$(arg_value STATE_ARGS "$game")" "${STATE_SPEC[$game]}"
    adb_push "$(arg_value INPUT_ARGS "$game")" "${INPUT_SPEC[$game]}"
    adb_shell "rm -f '${EVIDENCE_SPEC[$game]}'"

    # Sequential runs share the canonical root so libgcov merges their counters
    # into one flat dataset instead of producing colliding per-game basenames.
    game_gcov="$GCOV_DIR"
    game_log="$RA_LOG.$game"
    adb_shell "mkdir -p '$game_gcov'"

    config_flag=""
    [[ -n "$BASE_CONFIG" ]] && config_flag="-c '$BASE_CONFIG'"
    launch="cd '$DEVICE_DIR' || exit 1; GCOV_PREFIX='$game_gcov' GCOV_PREFIX_STRIP=1 "
    launch+="setsid '$RETROARCH_BIN' $config_flag --appendconfig '$OVERLAY' --verbose "
    launch+="--log-file '$game_log' -L '$DEVICE_DIR/$TRAIN_CORE_NAME' '$rom_spec'"

    runner="$(expand_runner "${RUNNER_SPEC[$game]}" "$game")"
    adb_shell "$launch >'$DEVICE_DIR/$game.stdout' 2>&1 </dev/null & echo \$! >'$DEVICE_DIR/$game.pid'; exit 0"
    adb_shell "sleep $RUNNER_WARMUP; kill -0 \$(cat '$DEVICE_DIR/$game.pid') 2>/dev/null"
    # The runner owns the training window and the advancing-frame evidence.
    adb_shell "cd '$DEVICE_DIR' || exit 1; setsid timeout $SECONDS_PER_GAME $runner >>'${EVIDENCE_SPEC[$game]}' 2>&1 & runner_pid=\$!; echo \$runner_pid >'$DEVICE_DIR/$game.runner.pid'; wait \$runner_pid; echo \$? >'$DEVICE_DIR/$game.runner.status'; rm -f '$DEVICE_DIR/$game.runner.pid'; exit 0"
    # Clean quit so libgcov flushes; SIGTERM would drop the counters.
    if [[ -n "$RETROARCHCTL" ]]; then
        adb_shell "'$RETROARCHCTL' --timeout-ms 3000 --port $NETCMD_PORT quit >/dev/null 2>&1 || true"
    else
        adb_shell "printf 'QUIT\\n' | nc -u 127.0.0.1 $NETCMD_PORT 2>/dev/null || printf 'QUIT\\n' | toybox nc -u 127.0.0.1 $NETCMD_PORT 2>/dev/null || true"
    fi
    adb_shell "for i in \$(seq 1 60); do pidof retroarch >/dev/null || break; sleep 1; done; pidof retroarch >/dev/null && exit 3; exit 0"

    if [[ "$DRY_RUN" == "1" ]]; then
        continue
    fi

    log="$PULL_DIR/logs/$game.log"
    evidence="$PULL_DIR/logs/$game.frames"
    mkdir -p "$(dirname "$log")"
    "${ADB[@]}" pull "$game_log" "$log" >/dev/null
    "${ADB[@]}" pull "${EVIDENCE_SPEC[$game]}" "$evidence" >/dev/null
    runner_status="$("${ADB[@]}" shell "cat '$DEVICE_DIR/$game.runner.status' 2>/dev/null" | tr -d '\r')"
    case "${runner_status:-}" in
        0 | 124) ;;
        *) die "$game input runner exited with status ${runner_status:-unknown}" ;;
    esac
    gcda_count="$("${ADB[@]}" shell "find '$game_gcov' -name '*.gcda' | wc -l" | tr -d '\r')"
    [[ "${gcda_count:-0}" -gt 0 ]] || die "$game wrote no .gcda files, so training did not run"
    grep -Fq -- "$DEVICE_DIR/$TRAIN_CORE_NAME" "$log" || die \
        "$game log does not show the staged generation core being loaded"
    for pattern in "${REQUIRE_LOG_PATTERNS[@]}"; do
        grep -Fq -- "$pattern" "$log" || die "$game log is missing required text: $pattern"
    done
    grep -Fq -- "$STATE_LOG_PATTERN" "$log" || die \
        "$game log shows no state load ('$STATE_LOG_PATTERN'); inspect $log and rerun with --state-log-pattern using the real wording"
    python3 - "$evidence" "$game" <<'PY'
import re
import sys

path, game = sys.argv[1], sys.argv[2]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError as error:
    raise SystemExit(f"{game}: runner evidence is missing: {error}")
samples = [int(value) for value in re.findall(r"frame=(\d+)", text)]
if len(samples) < 2:
    raise SystemExit(f"{game}: runner evidence has {len(samples)} frame samples, need at least 2")
if samples[-1] <= samples[0]:
    raise SystemExit(f"{game}: frames did not advance ({samples[0]} -> {samples[-1]})")
print(f"{game}: frames advanced {samples[0]} -> {samples[-1]}")
PY
    echo "trained $game: $gcda_count .gcda files after $SECONDS_PER_GAME seconds"
done

if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ adb pull %s %s\n' "$GCOV_DIR" "$PULL_DIR/raw"
    echo "dry run complete; nothing on the device was changed"
    exit 0
fi

rm -rf "$PULL_DIR/raw"
"${ADB[@]}" pull "$GCOV_DIR" "$PULL_DIR/raw" >/dev/null

gcda_total="$(find "$PULL_DIR/raw" -type f -name '*.gcda' | wc -l | tr -d ' ')"
renderer_total="$(find "$PULL_DIR/raw" -type f -name '*#core#rend#*.gcda' | wc -l | tr -d ' ')"
[[ "$gcda_total" -ge 50 ]] || die "pulled only $gcda_total .gcda files from the device"
[[ "$renderer_total" -gt 0 ]] || die "pulled no renderer profiles, so the renderer never ran"
echo "pulled $gcda_total .gcda files ($renderer_total renderer profiles) to $PULL_DIR/raw"

if [[ "$FREEZE" != "1" ]]; then
    echo "leaving the verified pull in $PULL_DIR/raw for the freeze command"
    exit 0
fi

device_serial="$ADB_SERIAL"
if [[ -z "$device_serial" ]]; then
    device_serial="$(adb devices | awk 'NR==2 {print $1}')"
fi

python3 "$PROFILE_TOOL" freeze \
    --profile-dir "$PROFILE_DIR" \
    --lock "$LOCK_PATH" \
    --patch "$PATCH_PATH" \
    --toolchain-id "$TOOLCHAIN_ID" \
    --canonical-source-dir "$CANONICAL_SOURCE_DIR" \
    --canonical-profile-dir "$CANONICAL_PROFILE_DIR" \
    "${SOURCE_ARGS[@]}" \
    --gcda-dir "$PULL_DIR/raw" \
    --options-file "$OPTIONS_FILE" \
    "${GAME_ARGS[@]}" \
    --seconds-per-game "$SECONDS_PER_GAME" \
    --generation-core-sha256 "$(sha256_of "$CORE_PATH")" \
    "${STATE_HASH_ARGS[@]}" \
    "${INPUT_HASH_ARGS[@]}" \
    --device "$device_serial" \
    --completed-utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --qualification "$QUALIFICATION"

echo "training complete; the frozen profile is in $PROFILE_DIR"
