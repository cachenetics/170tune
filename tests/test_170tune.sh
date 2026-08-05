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
    : > "$TMP/control/xid_sequence"
    : > "$TMP/control/ctx_rc_sequence"
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
    control_set selftest_complete 1
    control_set selftest_mode resident-two-phase-v1
    control_set selftest_result PASS
    control_set selftest_rc 0
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

cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$TMP/bin/date" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    -Is) printf '2026-08-05T12:00:00+08:00\n' ;;
    *) /bin/date "$@" ;;
esac
STUB

cat > "$TMP/bin/cat" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = /proc/sys/kernel/random/boot_id ]; then
    printf 'test-boot-id\n'
else
    /bin/cat "$@"
fi
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
c=${TEST_ROOT:?}/control
if [ -s "$c/xid_sequence" ]; then
    n=$(head -1 "$c/xid_sequence")
    sed '1d' "$c/xid_sequence" > "$c/xid_sequence.tmp"
    mv "$c/xid_sequence.tmp" "$c/xid_sequence"
else
    n=$(cat "$c/xid_count")
fi
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
printf 'MEM_ERRORS=%s COMPUTE_OK=%s MEM_SWEPT_MIB=%s MEM_COMPLETE=%s MEM_SWEEP_MODE=%s RESULT=%s\n' \
    "$(cat "$c/selftest_errors")" "$(cat "$c/selftest_compute_ok")" \
    "$(cat "$c/selftest_swept_mib")" "$(cat "$c/selftest_complete")" \
    "$(cat "$c/selftest_mode")" "$(cat "$c/selftest_result")"
exit "$(cat "$c/selftest_rc")"
STUB

cat > "$TMP/bin/compute_check" <<'STUB'
#!/usr/bin/env bash
printf 'compute_check %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
exit "$(cat "${TEST_ROOT}/control/compute_rc")"
STUB

cat > "$TMP/bin/ctx_probe" <<'STUB'
#!/usr/bin/env bash
printf 'ctx_probe %s\n' "$*" >> "${TEST_ROOT:?}/calls.log"
c=${TEST_ROOT}/control
if [ -s "$c/ctx_rc_sequence" ]; then
    rc=$(head -1 "$c/ctx_rc_sequence")
    sed '1d' "$c/ctx_rc_sequence" > "$c/ctx_rc_sequence.tmp"
    mv "$c/ctx_rc_sequence.tmp" "$c/ctx_rc_sequence"
else
    rc=$(cat "$c/ctx_rc")
fi
exit "$rc"
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
    SWEEP_FRAC="${SWEEP_FRAC:-0.95}" \
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
    assert_file_contains "$receipt" '"sweep_mode": "resident-two-phase-v1"'
    assert_file_contains "$receipt" '"sweep_fraction_milli": 950'
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

write_valid_sm_receipt() {
    mkdir -p "$TMP/state/gated/TESTSERIAL"
    cat > "$TMP/state/gated/TESTSERIAL/off100_clk1200.json" <<'EOF'
{"serial": "TESTSERIAL", "offset": 100, "ceiling": 1200, "mclk_mhz": 1728,
 "sweeps": 4, "peak_hbm_c": 65, "compute_check": true,
 "workload": "test", "gated": "2026-08-05T12:00:00+08:00"}
EOF
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

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"sweep_fraction_milli": 950/"sweep_fraction_milli": 1001/'
    assert_receipt_rejected "receipt claiming more than 100 percent coverage was accepted"
    printf 'PASS: HBM receipt contents are authoritative\n'
}

test_hbm_receipt_rejects_missing_required_fields() {
    reset_controls
    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"peak_hbm_c": 65,//'
    assert_receipt_rejected "receipt with no peak temperature was accepted"

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"sweeps": 4,//'
    assert_receipt_rejected "receipt with no sweep count was accepted"

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"sweep_mode": "resident-two-phase-v1",//'
    assert_receipt_rejected "legacy receipt with no resident sweep mode was accepted"

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"sweep_fraction_milli": 950,//'
    assert_receipt_rejected "receipt with no sweep coverage was accepted"

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"workload": "true",//'
    assert_receipt_rejected "receipt with no workload record was accepted"

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"workload_timeout": 10,//'
    assert_receipt_rejected "receipt with no workload timeout was accepted"

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"gated": "2026-08-05T12:00:00+08:00"/"gated": ""/'
    assert_receipt_rejected "receipt with no qualification timestamp was accepted"
    printf 'PASS: HBM receipt rejects missing required fields\n'
}

test_hbm_receipt_rejects_ambiguous_or_malformed_records() {
    reset_controls
    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"ndiv": 70,/"ndiv": 70, "ndiv": 70,/'
    assert_receipt_rejected "receipt with a duplicate authoritative key was accepted"

    receipt=$(write_valid_hbm_receipt)
    printf 'trailing garbage\n' >> "$receipt"
    assert_receipt_rejected "receipt with trailing garbage was accepted"

    receipt=$(write_valid_hbm_receipt)
    rewrite_receipt "$receipt" 's/"gated": "2026-08-05T12:00:00+08:00"/"gated": "yesterday"/'
    assert_receipt_rejected "receipt with an invalid qualification timestamp was accepted"
    printf 'PASS: HBM receipt rejects ambiguous or malformed records\n'
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

test_combined_hbm_gate_writes_exact_receipt() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    output=$(run_tune hbm-gate --ndiv 70 --timings "REFRESH 24" \
        --sweeps 4 --workload true 2>&1) ||
        fail "combined HBM gate rejected a clean profile: $output"
    assert_contains "$output" "HBM PROFILE QUALIFIED"
    assert_eq "$(cat "$TMP/control/ndiv")" 70
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 24
    receipt=$(find "$TMP/state/gated-hbm/TESTSERIAL" -name '*.json' -type f | head -1)
    [ -f "$receipt" ] || fail "combined HBM gate wrote no receipt"
    assert_file_contains "$receipt" '"ndiv": 70'
    assert_file_contains "$receipt" '"timings": "REFRESH 24"'
    assert_file_contains "$receipt" '"sweeps": 4'
    assert_file_contains "$receipt" '"workload": "true"'
    assert_file_contains "$receipt" '"workload_rc": 0'
    sweeps=$(grep -c '^gpu_selftest ' "$TMP/calls.log")
    assert_eq "$sweeps" 4
    printf 'PASS: combined HBM gate writes exact receipt\n'
}

test_hbm_gate_requires_at_least_95_percent_coverage() {
    reset_controls
    if SWEEP_FRAC=0.9499 run_tune hbm-gate --ndiv 70 --timings "REFRESH 24" \
        --sweeps 4 --workload true >/dev/null 2>&1; then
        fail "hbm-gate accepted SWEEP_FRAC below 0.95"
    fi
    assert_eq "$(cat "$TMP/control/ndiv")" 64
    printf 'PASS: HBM gate requires at least 95 percent sweep coverage\n'
}

run_rejected_hbm_gate() {
    rm -rf "$TMP/state/gated-hbm"
    set +e
    run_tune hbm-gate --ndiv 70 --timings "REFRESH 24" \
        --sweeps 4 --workload "${1:-true}" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$2 was accepted"
    [ ! -d "$TMP/state/gated-hbm/TESTSERIAL" ] ||
        [ -z "$(find "$TMP/state/gated-hbm/TESTSERIAL" -name '*.json' -type f -print -quit)" ] ||
        fail "$2 wrote a receipt"
    assert_eq "$(cat "$TMP/control/ndiv")" 64
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 6
}

test_combined_hbm_gate_rejects_and_reverts_failures() {
    reset_controls
    if run_tune hbm-gate --ndiv 70 --timings "CL 24" --sweeps 4 \
        --workload true >/dev/null 2>&1; then
        fail "timing without a known stock value was accepted"
    fi
    if grep -q '^fbpa_regs set CL ' "$TMP/calls.log"; then
        fail "unsupported timing was written before its rollback safety was checked"
    fi
    assert_eq "$(cat "$TMP/control/ndiv")" 64

    reset_controls
    control_set selftest_errors 1
    run_rejected_hbm_gate true "memory corruption"

    reset_controls
    control_set selftest_compute_ok 0
    run_rejected_hbm_gate true "selftest compute mismatch"

    reset_controls
    control_set selftest_complete 0
    run_rejected_hbm_gate true "incomplete resident sweep"

    reset_controls
    control_set selftest_mode legacy-sequential-v0
    run_rejected_hbm_gate true "legacy nonresident sweep"

    reset_controls
    control_set selftest_result FAIL
    run_rejected_hbm_gate true "selftest RESULT failure"

    reset_controls
    control_set selftest_rc 3
    run_rejected_hbm_gate true "selftest nonzero exit"

    reset_controls
    printf '0\n2\n' > "$TMP/control/ctx_rc_sequence"
    run_rejected_hbm_gate true "post-gate CUDA context failure"

    reset_controls
    run_rejected_hbm_gate false "workload failure"

    reset_controls
    control_set hbm_temp 59
    run_rejected_hbm_gate true "cold gate"

    reset_controls
    control_set timing_ignore_set 1
    run_rejected_hbm_gate true "timing readback mismatch"

    reset_controls
    control_set hbm_ignore_set 1
    run_rejected_hbm_gate true "NDIV readback mismatch"

    reset_controls
    printf '0\n1\n' > "$TMP/control/xid_sequence"
    run_rejected_hbm_gate true "new Xid"
    printf 'PASS: combined HBM gate rejects and reverts failures\n'
}

test_persist_rejects_nonstock_hbm_without_receipt() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    rm -f "$TMP/state/persist/TESTSERIAL.conf"
    if run_tune persist save --ndiv 70 >/dev/null 2>&1; then
        fail "non-stock HBM profile without a receipt was persisted"
    fi
    [ ! -f "$TMP/state/persist/TESTSERIAL.conf" ] ||
        fail "rejected HBM profile still wrote a persist config"
    printf 'PASS: persist rejects non-stock HBM without receipt\n'
}

test_persist_rejects_ambiguous_or_unrecoverable_timings() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    if run_tune persist save --timings "REFRESH 24" --force >/dev/null 2>&1; then
        fail "timings without an exact NDIV were persisted"
    fi
    if run_tune persist save --ndiv 70 --timings "CL 24" --force >/dev/null 2>&1; then
        fail "forced timing without a stock rollback value was persisted"
    fi
    printf 'PASS: persist rejects ambiguous or unrecoverable timings\n'
}

test_persist_rejects_malformed_sm_profile() {
    reset_controls
    if run_tune persist save --offset 100 >/dev/null 2>&1; then
        fail "persist save accepted an SM offset without a clock ceiling"
    fi
    if run_tune persist save --offset not-a-number --clk 1200 --force >/dev/null 2>&1; then
        fail "persist save accepted a nonnumeric SM offset"
    fi
    printf 'PASS: persist rejects malformed SM profiles\n'
}

test_persist_records_qualified_hbm_profile() {
    reset_controls
    write_valid_hbm_receipt >/dev/null
    rm -f "$TMP/state/persist/TESTSERIAL.conf"
    run_tune persist save --ndiv 70 --timings "refresh 24" >/dev/null 2>&1 ||
        fail "qualified HBM profile was rejected by persist save"
    conf="$TMP/state/persist/TESTSERIAL.conf"
    assert_file_contains "$conf" 'NDIV=70'
    assert_file_contains "$conf" 'TIMINGS="REFRESH 24"'
    assert_file_contains "$conf" 'HBM_FORCED=0'
    printf 'PASS: persist records a qualified HBM profile\n'
}

test_persist_marks_forced_hbm_profile() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    rm -f "$TMP/state/persist/TESTSERIAL.conf"
    output=$(run_tune persist save --ndiv 70 --timings "REFRESH 24" --force 2>&1) ||
        fail "explicit forced HBM persistence was rejected: $output"
    assert_contains "$output" "FORCED HBM persistence"
    conf="$TMP/state/persist/TESTSERIAL.conf"
    assert_file_contains "$conf" 'HBM_FORCED=1'
    assert_file_contains "$conf" 'unqualified forced HBM override'

    output=$(run_tune persist enable 2>&1) || fail "forced profile could not be enabled"
    assert_contains "$output" "forced HBM override"
    case "$output" in
        *"qualified profile"*) fail "forced HBM profile was described as qualified" ;;
    esac
    printf 'PASS: persist marks forced HBM profiles explicitly\n'
}

test_persist_keeps_sm_only_and_stock_hbm_compatible() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm" "$TMP/state/gated"
    rm -f "$TMP/state/persist/TESTSERIAL.conf"
    write_valid_sm_receipt
    run_tune persist save --offset 100 --clk 1200 >/dev/null 2>&1 ||
        fail "SM-only qualified profile was rejected"
    assert_file_contains "$TMP/state/persist/TESTSERIAL.conf" 'OFFSET=100'
    assert_file_contains "$TMP/state/persist/TESTSERIAL.conf" 'HBM_FORCED=0'

    rm -rf "$TMP/state/gated-hbm"
    run_tune persist save --ndiv 64 >/dev/null 2>&1 ||
        fail "stock-HBM profile required an HBM receipt"
    assert_file_contains "$TMP/state/persist/TESTSERIAL.conf" 'NDIV=64'
    assert_file_contains "$TMP/state/persist/TESTSERIAL.conf" 'HBM_FORCED=0'
    printf 'PASS: SM-only and stock-HBM persistence remain compatible\n'
}

test_persist_rejects_stale_hbm_receipt() {
    reset_controls
    write_valid_hbm_receipt >/dev/null
    rm -f "$TMP/state/persist/TESTSERIAL.conf"
    control_set driver 611.00
    if run_tune persist save --ndiv 70 --timings "REFRESH 24" >/dev/null 2>&1; then
        fail "persist save accepted an HBM receipt from another driver"
    fi
    [ ! -f "$TMP/state/persist/TESTSERIAL.conf" ] ||
        fail "stale receipt still wrote a persist config"
    printf 'PASS: persist rejects stale HBM receipts\n'
}

test_persist_enable_revalidates_hbm_receipt() {
    reset_controls
    write_valid_hbm_receipt >/dev/null
    run_tune persist save --ndiv 70 --timings "REFRESH 24" >/dev/null 2>&1 ||
        fail "test setup could not save qualified HBM profile"
    rm -rf "$TMP/state/gated-hbm"
    : > "$TMP/calls.log"
    if run_tune persist enable >/dev/null 2>&1; then
        fail "persist enable accepted a profile whose receipt was deleted"
    fi
    if grep -q '^systemctl enable ' "$TMP/calls.log"; then
        fail "persist enable reached systemd after HBM validation failed"
    fi
    printf 'PASS: persist enable revalidates HBM receipts\n'
}

test_persist_unit_pins_boot_context_probe() {
    reset_controls
    write_valid_hbm_receipt >/dev/null
    run_tune persist save --ndiv 70 --timings "REFRESH 24" >/dev/null 2>&1 ||
        fail "test setup could not save qualified HBM profile"
    rm -f "$TMP/persist.service"
    run_tune persist enable >/dev/null 2>&1 || fail "persist enable failed"
    assert_file_contains "$TMP/persist.service" "Environment=CTXPROBE=$TMP/bin/ctx_probe"
    assert_file_contains "$TMP/persist.service" 'Environment=CTX_TIMEOUT=10'
    printf 'PASS: persist unit pins the bounded boot context probe\n'
}

prepare_qualified_boot_profile() {
    reset_controls
    write_valid_hbm_receipt >/dev/null
    run_tune persist save --ndiv 70 --timings "REFRESH 24" >/dev/null 2>&1 ||
        fail "test setup could not save qualified boot profile"
    control_set ndiv 64
    control_set timing_REFRESH 6
    : > "$TMP/calls.log"
}

test_boot_apply_is_bounded_and_checks_context() {
    prepare_qualified_boot_profile
    run_tune boot-apply >/dev/null 2>&1 ||
        fail "boot-apply rejected a matching qualified profile"
    assert_eq "$(cat "$TMP/control/ndiv")" 70
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 24
    grep -q '^ctx_probe ' "$TMP/calls.log" ||
        fail "boot-apply accepted the profile without a CUDA context probe"
    if grep -qE '^(gpu_selftest|170hx-sweep|compute_check) ' "$TMP/calls.log"; then
        fail "boot-apply invoked a qualification workload"
    fi
    [ ! -f "$TMP/state/armed.json" ] || fail "successful boot-apply left the armed marker"
    printf 'PASS: boot apply is bounded and checks CUDA context\n'
}

test_boot_apply_rejects_missing_receipt_before_writes() {
    prepare_qualified_boot_profile
    rm -rf "$TMP/state/gated-hbm"
    if run_tune boot-apply >/dev/null 2>&1; then
        fail "boot-apply accepted a non-stock HBM profile without its receipt"
    fi
    assert_eq "$(cat "$TMP/control/ndiv")" 64
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 6
    if grep -qE '^(hbm_mclk set 70|fbpa_regs set REFRESH 24)' "$TMP/calls.log"; then
        fail "boot-apply wrote HBM registers before validating the receipt"
    fi
    printf 'PASS: boot apply rejects missing receipts before HBM writes\n'
}

test_boot_apply_rejects_timing_readback_mismatch() {
    prepare_qualified_boot_profile
    control_set timing_ignore_set 1
    if run_tune boot-apply >/dev/null 2>&1; then
        fail "boot-apply accepted a timing write that did not take"
    fi
    assert_eq "$(cat "$TMP/control/ndiv")" 64
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 6
    grep -q '^hbm_mclk set 64' "$TMP/calls.log" ||
        fail "timing readback failure did not invoke the stock NDIV fallback"
    printf 'PASS: boot apply rejects timing readback mismatch\n'
}

assert_boot_failure_reverted_stock() {
    if run_tune boot-apply >/dev/null 2>&1; then
        fail "$1 was accepted by boot-apply"
    fi
    assert_eq "$(cat "$TMP/control/ndiv")" 64
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 6
    [ ! -f "$TMP/state/armed.json" ] || fail "$1 left the armed marker"
}

test_boot_apply_rejects_ndiv_pll_context_and_runtime_faults() {
    prepare_qualified_boot_profile
    control_set hbm_ignore_set 1
    assert_boot_failure_reverted_stock "NDIV readback mismatch"

    prepare_qualified_boot_profile
    control_set hbm_set_rc 3
    assert_boot_failure_reverted_stock "PLL lock failure"

    prepare_qualified_boot_profile
    control_set ctx_rc 2
    assert_boot_failure_reverted_stock "CUDA context failure"

    prepare_qualified_boot_profile
    printf '0\n1\n' > "$TMP/control/xid_sequence"
    assert_boot_failure_reverted_stock "new Xid"

    prepare_qualified_boot_profile
    control_set sm_clock N/A
    assert_boot_failure_reverted_stock "runtime wedge"
    printf 'PASS: boot apply rejects NDIV, PLL, context, Xid, and wedge failures\n'
}

test_boot_apply_ignores_historical_xids() {
    prepare_qualified_boot_profile
    printf '2\n2\n' > "$TMP/control/xid_sequence"
    run_tune boot-apply >/dev/null 2>&1 ||
        fail "unchanged historical Xids caused boot-apply to reject the profile"
    assert_eq "$(cat "$TMP/control/ndiv")" 70
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 24
    printf 'PASS: boot apply ignores unchanged historical Xids\n'
}

test_boot_apply_rejects_stale_receipt_before_writes() {
    prepare_qualified_boot_profile
    control_set vbios 92.00.BAD
    if run_tune boot-apply >/dev/null 2>&1; then
        fail "boot-apply accepted an HBM receipt from another VBIOS"
    fi
    assert_eq "$(cat "$TMP/control/ndiv")" 64
    assert_eq "$(cat "$TMP/control/timing_REFRESH")" 6
    if grep -qE '^(hbm_mclk set 70|fbpa_regs set REFRESH 24)' "$TMP/calls.log"; then
        fail "boot-apply wrote HBM registers before stale receipt validation"
    fi
    printf 'PASS: boot apply rejects stale receipts before HBM writes\n'
}

test_boot_apply_logs_forced_profile() {
    reset_controls
    rm -rf "$TMP/state/gated-hbm"
    run_tune persist save --ndiv 70 --timings "REFRESH 24" --force >/dev/null 2>&1 ||
        fail "test setup could not save forced HBM profile"
    control_set ndiv 64
    control_set timing_REFRESH 6
    : > "$TMP/calls.log"
    run_tune boot-apply >/dev/null 2>&1 || fail "forced HBM profile was rejected at boot"
    grep -q 'logger .*HBM=forced' "$TMP/calls.log" ||
        fail "boot log did not identify the HBM profile as forced"
    printf 'PASS: boot apply labels forced HBM profiles\n'
}

test_persist_config_is_parsed_as_data() {
    reset_controls
    rm -f "$TMP/config-executed" "$TMP/enable-config-executed"
    cat > "$TMP/state/persist/TESTSERIAL.conf" <<EOF
NDIV=64
OFFSET=\$(touch "$TMP/config-executed")
CLK=1200
TIMINGS=""
HBM_FORCED=0
EOF
    if run_tune boot-apply >/dev/null 2>&1; then
        fail "boot-apply accepted executable text in the persist config"
    fi
    [ ! -e "$TMP/config-executed" ] || fail "boot-apply executed persist config as shell"

    cat > "$TMP/state/persist/TESTSERIAL.conf" <<EOF
NDIV=64
OFFSET=\$(touch "$TMP/enable-config-executed")
CLK=1200
TIMINGS=""
HBM_FORCED=0
EOF
    if run_tune persist enable >/dev/null 2>&1; then
        fail "persist enable accepted executable text in the persist config"
    fi
    [ ! -e "$TMP/enable-config-executed" ] || fail "persist enable executed persist config as shell"
    printf 'PASS: persist configs are parsed as data, not shell\n'
}

test_boot_apply_keeps_old_sm_only_profile_compatible() {
    reset_controls
    cat > "$TMP/state/persist/TESTSERIAL.conf" <<'EOF'
# legacy SM-only profile without HBM_FORCED
NDIV=
OFFSET=100
CLK=1200
TIMINGS=""
EOF
    : > "$TMP/calls.log"
    run_tune boot-apply >/dev/null 2>&1 ||
        fail "legacy SM-only profile was rejected at boot"
    grep -q '^nvml_oc 100 0' "$TMP/calls.log" || fail "SM offset was not applied"
    if grep -qE '^(hbm_mclk set|fbpa_regs set)' "$TMP/calls.log"; then
        fail "SM-only boot unexpectedly wrote HBM state"
    fi
    printf 'PASS: boot apply keeps legacy SM-only profiles compatible\n'
}

test_path_overrides_isolate_state
test_hbm_profile_identity_is_canonical
test_hbm_profile_rejects_malformed_timings
test_missing_hbm_receipt_is_rejected
test_exact_hbm_receipt_is_written_and_accepted
test_hbm_receipt_contents_are_authoritative
test_hbm_receipt_rejects_missing_required_fields
test_hbm_receipt_rejects_ambiguous_or_malformed_records
test_hbm_force_override_is_explicit
test_combined_hbm_gate_writes_exact_receipt
test_hbm_gate_requires_at_least_95_percent_coverage
test_combined_hbm_gate_rejects_and_reverts_failures
test_persist_rejects_nonstock_hbm_without_receipt
test_persist_rejects_ambiguous_or_unrecoverable_timings
test_persist_rejects_malformed_sm_profile
test_persist_records_qualified_hbm_profile
test_persist_marks_forced_hbm_profile
test_persist_keeps_sm_only_and_stock_hbm_compatible
test_persist_rejects_stale_hbm_receipt
test_persist_enable_revalidates_hbm_receipt
test_persist_unit_pins_boot_context_probe
test_boot_apply_is_bounded_and_checks_context
test_boot_apply_rejects_missing_receipt_before_writes
test_boot_apply_rejects_timing_readback_mismatch
test_boot_apply_rejects_ndiv_pll_context_and_runtime_faults
test_boot_apply_ignores_historical_xids
test_boot_apply_rejects_stale_receipt_before_writes
test_boot_apply_logs_forced_profile
test_persist_config_is_parsed_as_data
test_boot_apply_keeps_old_sm_only_profile_compatible
