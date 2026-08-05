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

assert_eq() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_file_contains() {
    [ -f "$1" ] || fail "missing file: $1"
    grep -Fq "$2" "$1" || fail "expected '$2' in $1"
}

assert_file_not_contains() {
    [ -f "$1" ] || fail "missing file: $1"
    if grep -Fq "$2" "$1"; then
        fail "did not expect '$2' in $1"
    fi
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

cat > "$TMP/bin/sync" <<'STUB'
#!/usr/bin/env bash
exit 0
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

test_hbm_profile_identity_is_canonical() {
    reset_controls
    id1=$(run_tune receipt-test id 70 "REFRESH 24 RAS 43" 2>/dev/null) ||
        fail "receipt-test id rejected a valid profile"
    id2=$(run_tune receipt-test id 70 "ras 43 refresh 24" 2>/dev/null) ||
        fail "receipt-test id rejected reordered timings"
    assert_eq "$id1" "$id2"
    case "$id1" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) fail "invalid HBM profile id: $id1" ;;
    esac
    printf 'PASS: HBM profile identity is canonical\n'
}

test_hbm_profile_rejects_malformed_timings() {
    reset_controls
    if run_tune receipt-test id 70 "REFRESH" >/dev/null 2>&1; then
        fail "odd timing token count was accepted"
    fi
    if run_tune receipt-test id 70 "REFRESH fast" >/dev/null 2>&1; then
        fail "nonnumeric timing value was accepted"
    fi
    if run_tune receipt-test id 70 "9BAD 24" >/dev/null 2>&1; then
        fail "invalid timing field was accepted"
    fi
    if run_tune receipt-test id 70 "REFRESH 24 refresh 25" >/dev/null 2>&1; then
        fail "duplicate timing field was accepted"
    fi
    printf 'PASS: malformed HBM timings are rejected\n'
}

test_missing_hbm_receipt_is_rejected() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    set +e
    output=$(run_tune receipt-test validate 70 "REFRESH 24" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "missing HBM receipt was accepted"
    assert_contains "$output" "no exact HBM gate receipt"
    printf 'PASS: missing HBM receipt is rejected\n'
}

test_exact_hbm_receipt_is_written_and_accepted() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    run_tune receipt-test write 70 "REFRESH 24" 4 65 true 0 >/dev/null
    run_tune receipt-test validate 70 "REFRESH 24" >/dev/null
    receipt=$(find "$TMP/state/gated-hbm/TESTSERIAL" -name '*.json' -type f | head -1)
    [ -n "$receipt" ] || fail "HBM receipt was not written"
    assert_file_contains "$receipt" '"device_id": "0x2082"'
    assert_file_contains "$receipt" '"driver_version": "610.43.03"'
    assert_file_contains "$receipt" '"vbios_version": "92.00.6D.00.0A"'
    assert_file_contains "$receipt" '"ndiv": 70'
    assert_file_contains "$receipt" '"timings": "REFRESH 24"'
    assert_file_contains "$receipt" '"sweeps": 4'
    assert_file_contains "$receipt" '"peak_hbm_c": 65'
    assert_file_contains "$receipt" '"compute_check": true'
    assert_file_contains "$receipt" '"context_check": true'
    assert_file_contains "$receipt" '"workload_rc": 0'
    assert_file_not_contains "$receipt" '"gated": ""'
    printf 'PASS: exact HBM receipt is written and accepted\n'
}

write_valid_hbm_receipt() {
    rm -rf "$TMP/state/gated-hbm"
    run_tune receipt-test write 70 "REFRESH 24" 4 65 true 0 >/dev/null
    find "$TMP/state/gated-hbm/TESTSERIAL" -name '*.json' -type f | head -1
}

assert_receipt_rejected() {
    if run_tune receipt-test validate 70 "REFRESH 24" >/dev/null 2>&1; then
        fail "$1"
    fi
}

rewrite_receipt() {
    sed "$2" "$1" > "$1.tmp"
    mv "$1.tmp" "$1"
}

test_hbm_receipt_contents_are_authoritative() {
    reset_controls
    receipt=$(write_valid_hbm_receipt)

    control_set driver 611.00
    assert_receipt_rejected "receipt from another driver was accepted"
    control_set driver 610.43.03

    control_set vbios 92.00.BAD
    assert_receipt_rejected "receipt from another VBIOS was accepted"
    control_set vbios 92.00.6D.00.0A

    control_set devid 0x20c2
    assert_receipt_rejected "receipt from another device ID was accepted"
    control_set devid 0x2082

    rewrite_receipt "$receipt" 's/"sweeps": 4/"sweeps": 3/'
    assert_receipt_rejected "thin HBM receipt was accepted"
    receipt=$(write_valid_hbm_receipt)

    rewrite_receipt "$receipt" 's/"peak_hbm_c": 65/"peak_hbm_c": 59/'
    assert_receipt_rejected "cold HBM receipt was accepted"
    receipt=$(write_valid_hbm_receipt)

    rewrite_receipt "$receipt" 's/"compute_check": true/"compute_check": false/'
    assert_receipt_rejected "receipt without compute proof was accepted"
    receipt=$(write_valid_hbm_receipt)

    rewrite_receipt "$receipt" 's/"context_check": true/"context_check": false/'
    assert_receipt_rejected "receipt without context proof was accepted"
    receipt=$(write_valid_hbm_receipt)

    rewrite_receipt "$receipt" 's/"workload_rc": 0/"workload_rc": 1/'
    assert_receipt_rejected "receipt with failed workload was accepted"
    printf 'PASS: HBM receipt contents are authoritative\n'
}

test_hbm_force_override_is_explicit() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    output=$(run_tune receipt-test validate-force 70 "REFRESH 24" 2>&1) ||
        fail "explicit HBM force override was rejected"
    assert_contains "$output" "FORCED HBM persistence"
    assert_contains "$output" "forced=1"

    write_valid_hbm_receipt >/dev/null
    output=$(run_tune receipt-test validate-force 70 "REFRESH 24" 2>&1) ||
        fail "valid HBM receipt was rejected with force available"
    assert_contains "$output" "forced=0"
    printf 'PASS: HBM force override is explicit\n'
}

test_path_overrides_isolate_state
test_hbm_profile_identity_is_canonical
test_hbm_profile_rejects_malformed_timings
test_missing_hbm_receipt_is_rejected
test_exact_hbm_receipt_is_written_and_accepted
test_hbm_receipt_contents_are_authoritative
test_hbm_force_override_is_explicit
