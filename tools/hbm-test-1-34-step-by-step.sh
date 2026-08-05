#!/usr/bin/env bash
# Safe, operator-confirmed HBM qualification and persistence rehearsal for the CMP 170HX on 1.34.
#
# This script deliberately does not reboot the host. It also refuses to save or enable a target
# profile unless the exact profile completed a real workload under a temperature guard.
set -Eeuo pipefail
umask 077

TUNE=${TUNE:-/usr/local/bin/170tune}
HBM_MCLK=${HBM_MCLK:-/usr/local/bin/hbm_mclk}
STATE=${STATE:-/var/lib/170tune}
BACKUP_ROOT=${BACKUP_ROOT:-/root/170tune-backups}
RUN_ROOT=${RUN_ROOT:-/var/tmp}
STOCK_NDIV=${STOCK_NDIV:-64}
STOCK_SWEEPS=${STOCK_SWEEPS:-4}
TARGET_SWEEPS=${TARGET_SWEEPS:-12}
WORKLOAD_TIMEOUT=${WORKLOAD_TIMEOUT:-28800}
GPU_TEMP_LIMIT=${GPU_TEMP_LIMIT:-86}
MEM_TEMP_LIMIT=${MEM_TEMP_LIMIT:-90}

DRY_RUN=0
TARGET_NDIV=""
TARGET_TIMINGS=""
PROBE_NDIV=""
WORKLOAD_CMD=""
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
RUN_DIR="$RUN_ROOT/170tune-hbm-test-$STAMP"
LOG="$RUN_DIR/run.log"
TELEMETRY="$RUN_DIR/telemetry.csv"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
TELEMETRY_PID=""
MOVED_RECEIPT_FROM=""
MOVED_RECEIPT_TO=""

usage() {
    cat <<'EOF'
Usage:
  hbm-test-1-34-step-by-step.sh [options]

Required for a persistence rehearsal:
  --target-ndiv N           exact final HBM NDIV to qualify
  --workload COMMAND        real serving/workload soak command

Optional:
  --target-timings STRING   exact timing pairs, for example: "REFRESH 24"
  --probe-ndiv N            run one optional four-sweep intermediate probe
  --target-sweeps N         final hot sweep count (default: 12)
  --workload-timeout SEC    workload timeout (default: 28800 / 8 hours)
  --gpu-temp-limit C        guarded workload core limit (default: 86 C)
  --mem-temp-limit C        guarded workload HBM limit (default: 90 C)
  --dry-run                 print every step and command; change nothing
  -h, --help                show this help

Safety properties:
  * every state-changing phase requires an operator confirmation;
  * existing 170tune state, binary and systemd units are backed up first;
  * active GPU workloads cause an immediate stop, never an automatic kill;
  * no --force is used;
  * an exact hbm-gate receipt is required before persist save;
  * persist enable requires typing the literal word ENABLE;
  * the script never reboots the host;
  * interruption attempts to restore the moved receipt and stock HBM state.

Example:
  sudo ./hbm-test-1-34-step-by-step.sh \
    --probe-ndiv 68 \
    --target-ndiv 70 \
    --target-timings "REFRESH 24" \
    --workload '/root/run-real-serving-soak.sh' \
    --workload-timeout 28800
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
    if [ "$DRY_RUN" -eq 0 ] && [ -n "${LOG:-}" ] && [ -d "${RUN_DIR:-/nonexistent}" ]; then
        printf '%s\n' "$*" >>"$LOG"
    fi
}

quote_cmd() {
    local arg out=""
    for arg in "$@"; do
        if [ -z "$out" ]; then
            printf -v out '%q' "$arg"
        else
            printf -v out '%s %q' "$out" "$arg"
        fi
    done
    printf '%s' "$out"
}

display_cmd() {
    local out
    out=$(quote_cmd "$@")
    out=${out//"$TUNE"/170tune}
    printf '%s' "$out"
}

run_cmd() {
    local shown
    shown=$(display_cmd "$@")
    say "+ $shown"
    [ "$DRY_RUN" -eq 1 ] && return 0
    "$@" 2>&1 | tee -a "$LOG"
}

run_shell() {
    local command_text=$1
    say "+ $command_text"
    [ "$DRY_RUN" -eq 1 ] && return 0
    bash -c "$command_text" 2>&1 | tee -a "$LOG"
}

run_expected_failure() {
    local shown rc
    shown=$(display_cmd "$@")
    say "+ EXPECT-FAIL: $shown"
    [ "$DRY_RUN" -eq 1 ] && return 0
    set +e
    "$@" 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    [ "$rc" -ne 0 ] || die "negative test unexpectedly succeeded: $shown"
    say "Expected refusal observed (exit $rc)."
}

confirm() {
    local prompt=$1 answer
    if [ "$DRY_RUN" -eq 1 ]; then
        say "DRY-RUN confirmation: $prompt -> yes"
        return 0
    fi
    [ -t 0 ] || die "interactive terminal required; rerun from an SSH terminal"
    printf '%s [y/N] ' "$prompt"
    read -r answer
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

confirm_enable() {
    local answer
    if [ "$DRY_RUN" -eq 1 ]; then
        say "DRY-RUN: type ENABLE to run: 170tune persist enable"
        return 0
    fi
    printf 'Type ENABLE to enable 170tune-persist.service; anything else leaves it disabled: '
    read -r answer
    [ "$answer" = ENABLE ]
}

step() {
    local number=$1 title=$2
    say ""
    say "================================================================"
    say "STEP $number - $title"
    say "================================================================"
}

numeric() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

count_xid() {
    dmesg 2>/dev/null | grep -cE 'NVRM: Xid|Xid [0-9]+|requires reset' || true
}

count_aer() {
    dmesg 2>/dev/null | grep -ciE 'AER:|PCIe Bus Error|Advanced Error Reporting' || true
}

gpu_processes() {
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
        sed '/^[[:space:]]*$/d' || true
}

known_gpu_services() {
    systemctl list-units --type=service --state=running --no-legend 2>/dev/null |
        grep -Ei 'vllm|comfy|qwen|cuda|llm|inference' || true
}

backup_item() {
    local source=$1 relative destination
    relative=${source#/}
    destination="$BACKUP_DIR/$relative"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "+ backup $source -> $destination"
        return 0
    fi
    if [ -e "$source" ] || [ -L "$source" ]; then
        mkdir -p "$(dirname "$destination")"
        cp -a -- "$source" "$destination"
        printf '%s\n' "$source" >>"$BACKUP_DIR/manifest.txt"
        say "Backed up: $source"
    else
        printf 'ABSENT %s\n' "$source" >>"$BACKUP_DIR/manifest.txt"
        say "Not present: $source"
    fi
}

start_telemetry() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say "+ nvidia-smi telemetry every 5 seconds -> $TELEMETRY"
        return 0
    fi
    (
        printf 'timestamp,name,serial,pstate,power_w,core_temp_c,mem_temp_c,sm_clock_mhz,mem_clock_mhz,util_gpu_pct,util_mem_pct,pcie_gen,pcie_width\n'
        while true; do
            nvidia-smi --query-gpu=timestamp,name,serial,pstate,power.draw,temperature.gpu,temperature.memory,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,pcie.link.gen.current,pcie.link.width.current \
                --format=csv,noheader,nounits 2>/dev/null || true
            sleep 5
        done
    ) >>"$TELEMETRY" 2>&1 &
    TELEMETRY_PID=$!
    say "Telemetry PID: $TELEMETRY_PID"
}

stop_telemetry() {
    if [ -n "$TELEMETRY_PID" ] && kill -0 "$TELEMETRY_PID" 2>/dev/null; then
        kill "$TELEMETRY_PID" 2>/dev/null || true
        wait "$TELEMETRY_PID" 2>/dev/null || true
    fi
    TELEMETRY_PID=""
}

restore_stock_best_effort() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    say "Best-effort stock restore: SM stock, stock timings, NDIV $STOCK_NDIV"
    "$TUNE" reset >>"$LOG" 2>&1 || true
    "$TUNE" timings-stock >>"$LOG" 2>&1 || true
    "$HBM_MCLK" set "$STOCK_NDIV" >>"$LOG" 2>&1 || true
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    stop_telemetry
    if [ -n "$MOVED_RECEIPT_FROM" ] && [ -f "$MOVED_RECEIPT_TO" ] && [ ! -e "$MOVED_RECEIPT_FROM" ]; then
        mv -- "$MOVED_RECEIPT_TO" "$MOVED_RECEIPT_FROM" || true
    fi
    if [ "$rc" -ne 0 ]; then
        restore_stock_best_effort
        say "Run failed or was interrupted (exit $rc). Evidence: $RUN_DIR"
    fi
    exit "$rc"
}

make_guarded_workload() {
    local guard="$RUN_DIR/guarded-workload.sh"
    [ "$DRY_RUN" -eq 1 ] && { printf '%s' "$guard"; return 0; }
    cat >"$guard" <<'GUARD'
#!/usr/bin/env bash
set -euo pipefail
: "${HBM_USER_WORKLOAD:?missing HBM_USER_WORKLOAD}"
: "${GPU_TEMP_LIMIT:?missing GPU_TEMP_LIMIT}"
: "${MEM_TEMP_LIMIT:?missing MEM_TEMP_LIMIT}"

if command -v setsid >/dev/null 2>&1; then
    setsid bash -lc "$HBM_USER_WORKLOAD" &
else
    bash -lc "$HBM_USER_WORKLOAD" &
fi
workload_pid=$!

terminate_workload() {
    kill -TERM -- "-$workload_pid" 2>/dev/null || kill -TERM "$workload_pid" 2>/dev/null || true
}
trap terminate_workload EXIT INT TERM

while kill -0 "$workload_pid" 2>/dev/null; do
    IFS=, read -r core_temp mem_temp < <(
        nvidia-smi --query-gpu=temperature.gpu,temperature.memory --format=csv,noheader,nounits 2>/dev/null |
            head -1 | tr -d ' '
    )
    printf 'temperature core=%sC memory=%sC limits=%s/%sC\n' \
        "${core_temp:-N/A}" "${mem_temp:-N/A}" "$GPU_TEMP_LIMIT" "$MEM_TEMP_LIMIT"
    if [[ "${core_temp:-}" =~ ^[0-9]+$ ]] && [ "$core_temp" -ge "$GPU_TEMP_LIMIT" ]; then
        printf 'temperature guard: core reached %sC\n' "$core_temp" >&2
        terminate_workload
        wait "$workload_pid" 2>/dev/null || true
        exit 86
    fi
    if [[ "${mem_temp:-}" =~ ^[0-9]+$ ]] && [ "$mem_temp" -ge "$MEM_TEMP_LIMIT" ]; then
        printf 'temperature guard: HBM reached %sC\n' "$mem_temp" >&2
        terminate_workload
        wait "$workload_pid" 2>/dev/null || true
        exit 90
    fi
    sleep 5
done

trap - EXIT INT TERM
wait "$workload_pid"
GUARD
    chmod 700 "$guard"
    printf '%s' "$guard"
}

run_target_gate() {
    local guard=$1 shown
    local args=("$TUNE" hbm-gate --ndiv "$TARGET_NDIV")
    [ -n "$TARGET_TIMINGS" ] && args+=(--timings "$TARGET_TIMINGS")
    args+=(--sweeps "$TARGET_SWEEPS" --workload "$guard")
    shown="170tune hbm-gate --ndiv $TARGET_NDIV"
    [ -n "$TARGET_TIMINGS" ] && shown="$shown --timings \"$TARGET_TIMINGS\""
    shown="$shown --sweeps $TARGET_SWEEPS --workload \"$guard\""
    say "+ WORKLOAD_TIMEOUT=$WORKLOAD_TIMEOUT GPU_TEMP_LIMIT=$GPU_TEMP_LIMIT MEM_TEMP_LIMIT=$MEM_TEMP_LIMIT $shown"
    [ "$DRY_RUN" -eq 1 ] && return 0
    HBM_USER_WORKLOAD="$WORKLOAD_CMD" \
    WORKLOAD_TIMEOUT="$WORKLOAD_TIMEOUT" \
    GPU_TEMP_LIMIT="$GPU_TEMP_LIMIT" \
    MEM_TEMP_LIMIT="$MEM_TEMP_LIMIT" \
        "${args[@]}" 2>&1 | tee -a "$LOG"
}

latest_receipt() {
    local serial=$1
    find "$STATE/gated-hbm/$serial" -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null |
        sort -n | tail -1 | cut -d' ' -f2-
}

validate_receipt() {
    local receipt=$1
    [ -f "$receipt" ] || die "no HBM receipt was written"
    python3 - "$receipt" "$TARGET_NDIV" "$TARGET_TIMINGS" "$WORKLOAD_TIMEOUT" <<'PY'
import json
import sys

path, ndiv, timings, timeout = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

errors = []
if data.get("ndiv") != int(ndiv):
    errors.append(f"ndiv={data.get('ndiv')} expected={ndiv}")
if data.get("timings", "") != timings:
    errors.append(f"timings={data.get('timings')!r} expected={timings!r}")
if data.get("sweeps", 0) < 4:
    errors.append("fewer than four sweeps")
if data.get("compute_check") is not True or data.get("context_check") is not True:
    errors.append("compute/context check not true")
if data.get("workload") in (None, ""):
    errors.append("no workload recorded")
if data.get("workload_rc") != 0:
    errors.append(f"workload_rc={data.get('workload_rc')}")
if data.get("workload_timeout") != int(timeout):
    errors.append(f"workload_timeout={data.get('workload_timeout')} expected={timeout}")

if errors:
    raise SystemExit("receipt validation failed: " + "; ".join(errors))
print(f"receipt validated: {path}")
PY
}

while [ $# -gt 0 ]; do
    case "$1" in
        --target-ndiv) TARGET_NDIV=${2:?missing value}; shift 2 ;;
        --target-timings) TARGET_TIMINGS=${2:?missing value}; shift 2 ;;
        --probe-ndiv) PROBE_NDIV=${2:?missing value}; shift 2 ;;
        --target-sweeps) TARGET_SWEEPS=${2:?missing value}; shift 2 ;;
        --workload) WORKLOAD_CMD=${2:?missing value}; shift 2 ;;
        --workload-timeout) WORKLOAD_TIMEOUT=${2:?missing value}; shift 2 ;;
        --gpu-temp-limit) GPU_TEMP_LIMIT=${2:?missing value}; shift 2 ;;
        --mem-temp-limit) MEM_TEMP_LIMIT=${2:?missing value}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

for value in "$STOCK_NDIV" "$STOCK_SWEEPS" "$TARGET_SWEEPS" "$WORKLOAD_TIMEOUT" "$GPU_TEMP_LIMIT" "$MEM_TEMP_LIMIT"; do
    numeric "$value" || die "numeric option expected, got: $value"
done
[ -z "$TARGET_NDIV" ] || numeric "$TARGET_NDIV" || die "invalid --target-ndiv: $TARGET_NDIV"
[ -z "$PROBE_NDIV" ] || numeric "$PROBE_NDIV" || die "invalid --probe-ndiv: $PROBE_NDIV"

if [ "$DRY_RUN" -eq 0 ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 ..."
    mkdir -p "$RUN_DIR"
    : >"$LOG"
    trap cleanup EXIT INT TERM
fi

say "170tune HBM step-by-step run"
say "Mode: $([ "$DRY_RUN" -eq 1 ] && printf 'DRY-RUN' || printf 'LIVE')"
say "Run directory: $RUN_DIR"
say "Target: NDIV=${TARGET_NDIV:-not-set}, timings='${TARGET_TIMINGS}', sweeps=$TARGET_SWEEPS"
say "Workload: $([ -n "$WORKLOAD_CMD" ] && printf 'configured' || printf 'not configured')"
say "This script will not reboot the host."

step 1 "Read-only environment, GPU identity and recovery-path check"
if ! confirm "Verify that SSH is stable and a physical/BMC recovery path is available, then continue?"; then
    die "operator did not confirm recovery access"
fi
run_cmd test -x "$TUNE"
run_cmd test -x "$HBM_MCLK"
run_shell 'command -v nvidia-smi'
run_shell 'command -v systemctl'
run_shell 'command -v python3'
run_cmd nvidia-smi --query-gpu=name,serial,pci.bus_id,pci.device_id,driver_version,vbios_version,memory.total --format=csv,noheader
run_shell 'systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service'

step 2 "Backup current 170tune state before any change"
if ! confirm "Create a timestamped backup under $BACKUP_DIR?"; then
    die "backup is mandatory"
fi
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$BACKUP_DIR"
    : >"$BACKUP_DIR/manifest.txt"
fi
backup_item /var/lib/170tune
backup_item /usr/local/bin/170tune
backup_item /usr/local/bin/hbm_mclk
backup_item /usr/local/bin/fbpa_regs
backup_item /usr/local/bin/ctx_probe
backup_item /etc/systemd/system/170tune-persist.service
backup_item /etc/systemd/system/170tune-bootcheck.service
run_shell 'systemctl is-enabled 170tune-persist.service 2>/dev/null || true'

step 3 "Require an idle GPU; do not kill workloads automatically"
if [ "$DRY_RUN" -eq 1 ]; then
    say "+ inspect nvidia-smi compute processes and running vLLM/ComfyUI/inference units"
else
    procs=$(gpu_processes)
    services=$(known_gpu_services)
    [ -z "$procs" ] || { printf '%s\n' "$procs" | tee -a "$LOG"; die "GPU processes are active; stop them manually and rerun"; }
    [ -z "$services" ] || { printf '%s\n' "$services" | tee -a "$LOG"; die "GPU-related services are active; stop them manually and rerun"; }
    say "No active GPU compute processes or known inference services found."
fi

step 4 "Disable automatic persistence before live testing"
run_shell 'systemctl is-enabled 170tune-persist.service 2>/dev/null || true'
if ! confirm "Disable and stop 170tune-persist.service while the test is running?"; then
    die "automatic persistence must be disabled during qualification"
fi
run_shell 'systemctl disable --now 170tune-persist.service 2>/dev/null || true'
run_cmd systemctl daemon-reload

step 5 "Capture baseline, run preflight and return SM/timings to stock"
run_cmd "$TUNE" status
run_cmd "$TUNE" mclk-status
run_cmd "$TUNE" persist status
run_cmd "$TUNE" preflight
run_cmd nvidia-smi -q
if ! confirm "Reset the live SM profile and HBM timings to stock before the control gate?"; then
    die "stock reset is mandatory"
fi
run_cmd "$TUNE" reset
run_cmd "$TUNE" timings-stock
if [ "$DRY_RUN" -eq 0 ]; then
    XID_BASE=$(count_xid)
    AER_BASE=$(count_aer)
    printf 'XID_BASE=%s\nAER_BASE=%s\n' "$XID_BASE" "$AER_BASE" >"$RUN_DIR/baseline.env"
    say "Baseline kernel counts: Xid=$XID_BASE AER=$AER_BASE"
else
    say "+ record baseline Xid/AER counts"
fi
start_telemetry

step 6 "Stock HBM positive control"
say "Command: 170tune hbm-gate --ndiv $STOCK_NDIV --sweeps $STOCK_SWEEPS"
if ! confirm "Run the stock NDIV $STOCK_NDIV hot correctness gate?"; then
    die "stock positive control was not approved"
fi
run_cmd "$TUNE" hbm-gate --ndiv "$STOCK_NDIV" --sweeps "$STOCK_SWEEPS"
run_cmd "$TUNE" mclk-status

step 7 "Optional intermediate NDIV probe"
if [ -n "$PROBE_NDIV" ]; then
    say "This is a volatile probe only. It will not be saved or enabled."
    if confirm "Run NDIV $PROBE_NDIV with four hot sweeps?"; then
        run_cmd "$TUNE" hbm-gate --ndiv "$PROBE_NDIV" --sweeps 4
        run_cmd "$TUNE" mclk-status
    else
        say "Intermediate probe skipped by operator."
    fi
else
    say "Skipped: no --probe-ndiv was supplied."
fi

step 8 "Exact target qualification with a real guarded workload"
if [ -z "$TARGET_NDIV" ] || [ -z "$WORKLOAD_CMD" ]; then
    say "STOP: persistence rehearsal requires both --target-ndiv and --workload."
    say "No profile was saved or enabled. Re-run with the missing argument(s)."
    restore_stock_best_effort
    stop_telemetry
    trap - EXIT INT TERM
    exit 0
fi
say "Target: NDIV $TARGET_NDIV; timings '${TARGET_TIMINGS}'; sweeps $TARGET_SWEEPS."
say "The workload is bounded by $WORKLOAD_TIMEOUT seconds and temperature limits $GPU_TEMP_LIMIT/$MEM_TEMP_LIMIT C."
if ! confirm "Run the final combined hbm-gate now?"; then
    die "final qualification was not approved"
fi
GUARD=$(make_guarded_workload)
run_target_gate "$GUARD"
if [ "$DRY_RUN" -eq 1 ]; then
    SERIAL=DRYRUNSERIAL
    RECEIPT="$STATE/gated-hbm/$SERIAL/<exact-profile>.json"
    say "+ validate exact receipt for serial $SERIAL, NDIV $TARGET_NDIV, timings '$TARGET_TIMINGS'"
else
    SERIAL=$(nvidia-smi --query-gpu=serial --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    RECEIPT=$(latest_receipt "$SERIAL")
    validate_receipt "$RECEIPT" 2>&1 | tee -a "$LOG"
fi
run_cmd "$TUNE" mclk-status
run_cmd "$TUNE" timings dump

step 9 "Check kernel errors and save the qualified profile without enabling it"
if [ "$DRY_RUN" -eq 0 ]; then
    XID_NOW=$(count_xid)
    AER_NOW=$(count_aer)
    . "$RUN_DIR/baseline.env"
    say "Kernel counts now: Xid=$XID_NOW (base $XID_BASE), AER=$AER_NOW (base $AER_BASE)"
    [ "$XID_NOW" -le "$XID_BASE" ] || die "new Xid detected"
    [ "$AER_NOW" -le "$AER_BASE" ] || die "new AER/PCIe error detected"
else
    say "+ verify Xid and AER counts did not increase"
fi
if ! confirm "Save this exact receipt-qualified profile, but keep the service disabled?"; then
    die "profile save was not approved"
fi
SAVE_ARGS=("$TUNE" persist save --ndiv "$TARGET_NDIV")
[ -n "$TARGET_TIMINGS" ] && SAVE_ARGS+=(--timings "$TARGET_TIMINGS")
run_cmd "${SAVE_ARGS[@]}"
run_cmd "$TUNE" persist status
if [ "$DRY_RUN" -eq 0 ]; then
    CONF="$STATE/persist/$SERIAL.conf"
    grep -Fxq 'HBM_FORCED=0' "$CONF" || die "persist config is missing HBM_FORCED=0"
    say "Confirmed HBM_FORCED=0 in $CONF"
else
    say "+ verify persist config contains HBM_FORCED=0"
fi

step 10 "Negative receipt test: boot-apply must refuse before BAR0 writes"
if confirm "Temporarily move the exact receipt and verify boot-apply refuses it?"; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "+ move receipt aside; EXPECT-FAIL: 170tune boot-apply; restore receipt"
    else
        [ -f "$RECEIPT" ] || die "receipt disappeared before negative test"
        MOVED_RECEIPT_FROM=$RECEIPT
        MOVED_RECEIPT_TO="$RUN_DIR/receipt-negative-test.json"
        mv -- "$MOVED_RECEIPT_FROM" "$MOVED_RECEIPT_TO"
        run_expected_failure "$TUNE" boot-apply
        mv -- "$MOVED_RECEIPT_TO" "$MOVED_RECEIPT_FROM"
        MOVED_RECEIPT_FROM=""
        MOVED_RECEIPT_TO=""
        say "Receipt restored after expected refusal."
    fi
else
    say "Negative receipt test skipped by operator."
fi

step 11 "Manual stock restore, then one positive boot-apply rehearsal"
if ! confirm "Restore stock and run boot-apply once without enabling the service?"; then
    die "positive boot-apply rehearsal was not approved"
fi
run_cmd "$TUNE" reset
run_cmd "$TUNE" timings-stock
run_cmd "$HBM_MCLK" set "$STOCK_NDIV"
run_cmd "$TUNE" mclk-status
run_cmd "$TUNE" boot-apply
run_cmd "$TUNE" mclk-status
run_cmd "$TUNE" timings dump
run_cmd nvidia-smi --query-gpu=name,serial,pstate,power.draw,temperature.gpu,temperature.memory,clocks.sm,clocks.mem,pci.link.gen.current,pci.link.width.current --format=csv,noheader

step 12 "Optional enable; never reboot from this script"
say "The service is still disabled. Enabling it changes the next boot path."
if confirm_enable; then
    run_cmd "$TUNE" persist enable
    run_cmd "$TUNE" persist status
    say "Persistence is enabled. Do not reboot until SSH and physical/BMC recovery are confirmed again."
else
    say "Persistence remains disabled."
fi
say "No reboot command will be run. When ready, reboot manually in a separate maintenance step."

step 13 "Return this boot to stock and write final evidence"
run_cmd "$TUNE" reset
run_cmd "$TUNE" timings-stock
run_cmd "$HBM_MCLK" set "$STOCK_NDIV"
run_cmd "$TUNE" mclk-status
run_cmd nvidia-smi --query-gpu=name,serial,pstate,power.draw,temperature.gpu,temperature.memory,memory.used,clocks.sm,clocks.mem,pci.link.gen.current,pci.link.width.current --format=csv,noheader
if [ "$DRY_RUN" -eq 0 ]; then
    XID_FINAL=$(count_xid)
    AER_FINAL=$(count_aer)
    . "$RUN_DIR/baseline.env"
    printf 'state=completed\nserial=%s\ntarget_ndiv=%s\ntarget_timings=%s\nxid_base=%s\nxid_final=%s\naer_base=%s\naer_final=%s\n' \
        "$SERIAL" "$TARGET_NDIV" "$TARGET_TIMINGS" "$XID_BASE" "$XID_FINAL" "$AER_BASE" "$AER_FINAL" \
        >"$RUN_DIR/summary.env"
    [ "$XID_FINAL" -le "$XID_BASE" ] || die "new Xid detected at final check"
    [ "$AER_FINAL" -le "$AER_BASE" ] || die "new AER/PCIe error detected at final check"
fi
stop_telemetry
trap - EXIT INT TERM
say "Completed without reboot."
say "Evidence: $RUN_DIR"
say "Backup: $BACKUP_DIR"
