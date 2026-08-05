#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/control" "$TMP/state/persist"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "expected '$2' in: $1" ;;
    esac
}

assert_file_contains() {
    [ -f "$1" ] || fail "missing file: $1"
    grep -Fq "$2" "$1" || fail "expected '$2' in $1"
}

control_set() {
    printf '%s\n' "$2" > "$TMP/control/$1"
}

reset_controls() {
    : > "$TMP/calls.log"
    control_set serial TESTSERIAL
    control_set devid 0x2082
    control_set driver 610.43.03
    control_set vbios 92.00.6D.00.0A
    control_set sm_clock 1200
    control_set mem_clock 1728
    control_set core_temp 55
    control_set hbm_temp 65
    control_set ndiv 64
    control_set pll_lock 1
    control_set hbm_set_rc 0
    control_set hbm_ignore_set 0
    control_set ctx_rc 0
    control_set compute_rc 0
    control_set xid_count 0
    control_set selftest_errors 0
    control_set selftest_compute_ok 1
    control_set selftest_swept_mib 8192
    control_set timing_set_rc 0
    control_set timing_ignore_set 0
    control_set timing_REFRESH 6
    control_set timing_RAS 43
    control_set systemctl_enabled disabled
}

cat > "$TMP/bin/id" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    -u) printf '0\n' ;;
    -un) printf 'root\n' ;;
    *) /usr/bin/id "$@" ;;
esac
STUB

cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB

cat > "$TMP/bin/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
set -u
c=${TEST_ROOT:?}/control
printf 'nvidia-smi %s\n' "$*" >> "${TEST_ROOT}/calls.log"
case "$*" in
    *--query-gpu=serial*) cat "$c/serial" ;;
    *--query-gpu=pci.device_id*) cat "$c/devid" ;;
    *--query-gpu=driver_version*) cat "$c/driver" ;;
    *--query-gpu=vbios_version*) cat "$c/vbios" ;;
    *--query-gpu=clocks.current.memory*) cat "$c/mem_clock" ;;
    *--query-gpu=clocks.mem*) cat "$c/mem_clock" ;;
    *--query-gpu=clocks.sm*) printf '%s MHz\n' "$(cat "$c/sm_clock")" ;;
    *--query-gpu=temperature.memory*) cat "$c/hbm_temp" ;;
    *--query-gpu=temperature.gpu*) cat "$c/core_temp" ;;
    *--query-gpu=memory.total*) printf '65536 MiB\n' ;;
    *--query-gpu=pcie.link.gen.gpucurrent*) printf '2\n' ;;
    *) exit 0 ;;
esac
STUB

cat > "$TMP/bin/dmesg" <<'STUB'
#!/usr/bin/env bash
n=$(cat "${TEST_ROOT:?}/control/xid_count")
i=0
while [ "$i" -lt "$n" ]; do
    printf 'NVRM: Xid 13\n'
    i=$((i + 1))
done
STUB

cat > "$TMP/bin/logger" <<'STUB'
#!/usr/bin/env bash
printf 'logger %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
STUB

cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
case "${1:-}" in
    is-enabled) cat "${TEST_ROOT}/control/systemctl_enabled" ;;
    *) exit 0 ;;
esac
STUB

cat > "$TMP/bin/nvml_oc" <<'STUB'
#!/usr/bin/env bash
printf 'nvml_oc %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
exit 0
STUB

cat > "$TMP/bin/hbm_mclk" <<'STUB'
#!/usr/bin/env bash
set -u
c=${TEST_ROOT:?}/control
printf 'hbm_mclk %s\n' "$*" >> "${TEST_ROOT}/calls.log"
case "${1:-}" in
    get)
        printf 'NDIV %s  (%s MHz)  COEFF 0x00014001  lock %s  PLM 0x00000010\n' \
            "$(cat "$c/ndiv")" "$(( $(cat "$c/ndiv") * 27 ))" "$(cat "$c/pll_lock")"
        ;;
    set)
        rc=$(cat "$c/hbm_set_rc")
        [ "$rc" -eq 0 ] || exit "$rc"
        [ "$(cat "$c/hbm_ignore_set")" -eq 1 ] || printf '%s\n' "$2" > "$c/ndiv"
        ;;
    ddll) exit 0 ;;
    *) exit 0 ;;
esac
STUB

cat > "$TMP/bin/fbpa_regs" <<'STUB'
#!/usr/bin/env bash
set -u
c=${TEST_ROOT:?}/control
printf 'fbpa_regs %s\n' "$*" >> "${TEST_ROOT}/calls.log"
case "${1:-}" in
    get)
        f=$2
        [ -f "$c/timing_$f" ] || exit 1
        cat "$c/timing_$f"
        ;;
    set)
        rc=$(cat "$c/timing_set_rc")
        [ "$rc" -eq 0 ] || exit "$rc"
        [ "$(cat "$c/timing_ignore_set")" -eq 1 ] || printf '%s\n' "$3" > "$c/timing_$2"
        ;;
    *) exit 0 ;;
esac
STUB

cat > "$TMP/bin/gpu_selftest" <<'STUB'
#!/usr/bin/env bash
c=${TEST_ROOT:?}/control
printf 'gpu_selftest %s\n' "$*" >> "${TEST_ROOT}/calls.log"
printf 'MEM_ERRORS=%s COMPUTE_OK=%s MEM_SWEPT_MIB=%s\n' \
    "$(cat "$c/selftest_errors")" "$(cat "$c/selftest_compute_ok")" \
    "$(cat "$c/selftest_swept_mib")"
STUB

cat > "$TMP/bin/compute_check" <<'STUB'
#!/usr/bin/env bash
printf 'compute_check %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
exit "$(cat "${TEST_ROOT}/control/compute_rc")"
STUB

cat > "$TMP/bin/ctx_probe" <<'STUB'
#!/usr/bin/env bash
printf 'ctx_probe %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
exit "$(cat "${TEST_ROOT}/control/ctx_rc")"
STUB

cat > "$TMP/bin/oc_eff" <<'STUB'
#!/usr/bin/env bash
printf 'oc_eff %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
exit 0
STUB

cat > "$TMP/bin/170hx-sweep" <<'STUB'
#!/usr/bin/env bash
printf '170hx-sweep %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
printf 'mem_errors=0 compute_ok=1\n'
STUB

chmod +x "$TMP/bin/"*

run_tune() {
    PATH="$TMP/bin:$PATH" \
    TEST_ROOT="$TMP" \
    TUNE_TEST_MODE=1 \
    STATE="$TMP/state" \
    PERSIST="$TMP/state/persist" \
    PERSIST_UNIT="$TMP/persist.service" \
    NVML="$TMP/bin/nvml_oc" \
    OCEFF="$TMP/bin/oc_eff" \
    BENCH="$TMP/bin/170hx-sweep" \
    COMPUTE="$TMP/bin/compute_check" \
    CTXPROBE="$TMP/bin/ctx_probe" \
    HBM_MCLK="$TMP/bin/hbm_mclk" \
    FBPA_REGS="$TMP/bin/fbpa_regs" \
    SELFTEST="$TMP/bin/gpu_selftest" \
    GATE_TEMP=60 \
    GATE_SOAK_MAX=1 \
    MCLK_GATE_SOAK_MAX=1 \
    GATE_COMPUTE=1 \
    SWEEP_TIMEOUT=10 \
    WORKLOAD_TIMEOUT=10 \
    CTX_TIMEOUT=10 \
    bash "$ROOT/tools/170tune" "$@"
}

test_path_overrides_isolate_state() {
    reset_controls
    cat > "$TMP/state/persist/TESTSERIAL.conf" <<'EOF'
# isolated-test-marker
NDIV=64
OFFSET=
CLK=
TIMINGS=""
EOF
    output=$(run_tune persist status 2>&1 || true)
    assert_contains "$output" "isolated-test-marker"
    printf 'PASS: path overrides isolate state\n'
}

test_path_overrides_isolate_state
