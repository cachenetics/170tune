#!/usr/bin/env bash
# Behavioral tests for tools/170hx-oc. nvidia-smi and nvml_oc are stubbed; no hardware touched.
#
# Regression target: nvml_oc always exits 0 even when the driver silently drops a VF-offset write
# (NVML reports Success; only the readback shows the truth - see nvml_oc.c's own WARNING, which
# 170hx-oc used to discard via `>/dev/null`). The old `nvml_oc ... || echo REFUSED` could never
# fire. Fixed by comparing the readback 170hx-oc already computes against the requested offset.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/control"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected '$2' in: $1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "did not expect '$2' in: $1" ;; esac; }

# 170hx-oc calls nvml_oc by a hardcoded absolute path (it is meant to run installed at
# /usr/local/bin on a real box) - PATH cannot intercept that. Copy the script and substitute the
# call site instead, same idea as the sibling suite isolating STATE/PERSIST via env vars.
SCRIPT="$TMP/170hx-oc"
sed 's#/usr/local/bin/nvml_oc#'"$TMP"'/bin/nvml_oc#g' "$ROOT/tools/170hx-oc" > "$SCRIPT"
chmod +x "$SCRIPT"

cat > "$TMP/bin/nvidia-smi" <<STUB
#!/usr/bin/env bash
c="$TMP/control"
case "\$*" in
  -pm*) exit 0 ;;
  --query-gpu=index,pci.device_id,serial*) printf '0, 0x20C2, TESTSERIAL\n' ;;
  *-pl*) [ "\$(cat "\$c/pl_rc")" = 0 ] || exit 1; exit 0 ;;
  *-lgc*) [ "\$(cat "\$c/lgc_rc")" = 0 ] || exit 1; exit 0 ;;
  *-rgc*) exit 0 ;;
  *--query-gpu=power.limit*) cat "\$c/power_limit_report" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/nvidia-smi"

reset_control() {
    printf '0\n' > "$TMP/control/pl_rc"
    printf '0\n' > "$TMP/control/lgc_rc"
    printf '300.00 W\n' > "$TMP/control/power_limit_report"
}

# $1 = the signed value ("+250", "+0", ...) nvml_oc's `-i` readback reports for this GPU.
stub_nvml_readback() {
    local val="$1"
    cat > "$TMP/bin/nvml_oc" <<STUB2
#!/usr/bin/env bash
case "\${1:-}" in
  -i) printf 'current offset     : Success  ${val} MHz\n' ;;
  *) exit 0 ;;
esac
STUB2
    chmod +x "$TMP/bin/nvml_oc"
}

run() { PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }

test_offset_silently_dropped_by_the_driver_is_reported() {
    reset_control
    stub_nvml_readback "+0"
    output=$(run custom 250 1400)
    assert_contains "$output" "offset 250 REFUSED"
    assert_contains "$output" "readback: +0"
    assert_contains "$output" "offset=+0"
    printf 'PASS: a silently-dropped offset write (NVML Success, readback unchanged) is reported\n'
}

test_offset_that_actually_applies_is_not_flagged() {
    reset_control
    stub_nvml_readback "+250"
    output=$(run custom 250 1400)
    assert_not_contains "$output" "REFUSED"
    assert_contains "$output" "offset=+250"
    printf 'PASS: an offset that genuinely applies is not falsely flagged REFUSED\n'
}

test_power_limit_and_clock_ceiling_refusals_are_still_reported() {
    reset_control
    printf '1\n' > "$TMP/control/pl_rc"
    printf '1\n' > "$TMP/control/lgc_rc"
    printf '150.00 W\n' > "$TMP/control/power_limit_report"
    stub_nvml_readback "+0"
    output=$(run custom 250 1400)
    assert_contains "$output" "power limit 300 W REFUSED"
    assert_contains "$output" "clock ceiling 1400 REFUSED"
    printf 'PASS: power limit and clock ceiling refusals still surface (nvidia-smi exit code path, unchanged)\n'
}

test_offset_silently_dropped_by_the_driver_is_reported
test_offset_that_actually_applies_is_not_flagged
test_power_limit_and_clock_ceiling_refusals_are_still_reported
printf '\nALL PASS (170hx-oc)\n'
