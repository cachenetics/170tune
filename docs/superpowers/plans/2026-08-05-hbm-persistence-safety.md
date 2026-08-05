# HBM Persistence Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require exact, per-card qualification evidence before a non-stock HBM profile is persisted, then perform bounded receipt, register-readback, CUDA-context, and Xid checks when that fixed profile is applied at boot.

**Architecture:** Add an exact-profile HBM receipt alongside the existing SM receipt system. A new `hbm-gate` command applies and tests the complete NDIV/timing combination and writes the receipt; `persist save`, `persist enable`, and `boot-apply` validate that receipt. Boot performs only quick validation and never repeats the hot full-VRAM qualification.

**Tech Stack:** Bash 4+, existing `hbm_mclk`, `fbpa_regs`, CUDA probes, `nvidia-smi`, systemd, shell integration tests with stub executables.

## Global Constraints

- Preserve the existing default paths: `/var/lib/170tune` and `/etc/systemd/system/170tune-persist.service`.
- Do not add a Python, jq, or non-base-system runtime dependency.
- Do not change PLL addresses, timing fields, safe NDIV recommendations, VBIOS, driver modules, capacity unlock, GPC unlock, PCIe retraining, or power-limit behavior.
- Do not run a full-VRAM sweep or long workload from `boot-apply`.
- Keep SM receipts and HBM receipts separate.
- Keep `--force` as an explicit compatibility override and record `HBM_FORCED=1` in the persisted profile.
- Treat the current upstream commit `2805681ab5560d5b755733c13cd586f05e692140` as the behavioral baseline.
- Run every production-code change through a witnessed red-green test cycle.

---

## File map

- Modify `tools/170tune`: path overrides, environment fingerprint helpers, HBM profile normalization, receipt creation and validation, `hbm-gate`, persistence enforcement, and bounded boot validation.
- Create `tests/test_170tune.sh`: GPU-free shell integration harness with temporary state and command stubs.
- Modify `README.md`: document the exact HBM qualification/persistence workflow and migration behavior.
- Modify `docs/tuning-guide.md`: replace direct HBM persistence examples with `hbm-gate` and explain what boot checks do.

### Task 1: Build the GPU-free control-flow test harness

**Files:**
- Create: `tests/test_170tune.sh`
- Modify: `tools/170tune:36-37,92-93`

**Interfaces:**
- Consumes: existing CLI entry point `tools/170tune`.
- Produces: environment overrides `STATE`, `PERSIST`, and `PERSIST_UNIT`; test helper `run_tune`; stub commands for `id`, `nvidia-smi`, `dmesg`, `logger`, `systemctl`, `timeout`, `nvml_oc`, `hbm_mclk`, `fbpa_regs`, `gpu_selftest`, and `ctx_probe`.

- [ ] **Step 1: Read the test-quality rules before creating tests**

Read:

```bash
sed -n '1,260p' /Users/lzk/.codex/plugins/cache/claude-plugins-official/superpowers/6.2.0/skills/test-driven-development/writing-good-tests.md
```

- [ ] **Step 2: Write a failing path-isolation test**

Create `tests/test_170tune.sh` with a minimal assertion framework and this first behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state/persist"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected '$2' in: $1" ;; esac; }

cat >"$TMP/bin/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--query-gpu=serial*) printf 'TESTSERIAL\n' ;;
  *--query-gpu=pci.device_id*) printf '0x2082\n' ;;
  *--query-gpu=clocks.sm*) printf '1200 MHz\n' ;;
  *--query-gpu=clocks.mem*) printf '1593 MHz\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/nvidia-smi"

output=$(PATH="$TMP/bin:$PATH" STATE="$TMP/state" PERSIST="$TMP/state/persist" \
  PERSIST_UNIT="$TMP/persist.service" bash "$ROOT/tools/170tune" persist status 2>&1 || true)
assert_contains "$output" "no persist profile for TESTSERIAL"
[ ! -e /var/lib/170tune/persist/TESTSERIAL.conf ] || fail "test touched production state"
printf 'PASS: path overrides isolate state\n'
```

- [ ] **Step 3: Run the new test and witness the expected failure**

Run:

```bash
bash tests/test_170tune.sh
```

Expected: FAIL because `tools/170tune` overwrites `STATE` and `PERSIST` with `/var/lib/170tune` paths instead of honoring the temporary paths.

- [ ] **Step 4: Implement environment-overridable paths**

Change the path declarations to:

```bash
STATE=${STATE:-/var/lib/170tune}
PERSIST=${PERSIST:-$STATE/persist}
PERSIST_UNIT=${PERSIST_UNIT:-/etc/systemd/system/170tune-persist.service}
```

- [ ] **Step 5: Complete the reusable command stubs**

Extend `tests/test_170tune.sh` so each stub reads behavior from files below `$TMP/control`. Use these exact controls:

```text
serial, devid, driver, vbios, sm_clock, mem_clock, core_temp, hbm_temp,
ndiv, pll_lock, ctx_rc, xid_count, selftest_errors, selftest_compute_ok,
timing_<FIELD>, systemctl_enabled
```

The `timeout` stub must discard its first argument and `exec "$@"`. The `id` stub must return `0` for `id -u` and `root` for `id -un`. Every mutating stub appends its arguments to `$TMP/calls.log` so later tests can assert that a full-VRAM self-test was not invoked during boot.

- [ ] **Step 6: Run the harness and verify green**

Run:

```bash
bash tests/test_170tune.sh
bash -n tools/170tune tests/test_170tune.sh
```

Expected: both commands exit 0 and the test prints `PASS: path overrides isolate state`.

- [ ] **Step 7: Commit the harness boundary**

```bash
git add tools/170tune tests/test_170tune.sh
git commit -m "test: add isolated 170tune shell harness"
```

### Task 2: Define exact HBM profile identity and receipt validation

**Files:**
- Modify: `tools/170tune:103-179,1228-1325`
- Test: `tests/test_170tune.sh`

**Interfaces:**
- Consumes: `serial`, `devid`, `nvidia-smi`, `STATE`, `GATE_TEMP`.
- Produces:
  - `driver_version() -> string`
  - `vbios_version() -> string`
  - `normalize_timings(string) -> canonical string or nonzero`
  - `hbm_profile_id(ndiv, canonical_timings) -> 16 lowercase hex characters`
  - `hbm_receipt_file(ndiv, canonical_timings) -> path`
  - `write_hbm_receipt(ndiv, timings, sweeps, peak_hbm, workload, workload_rc) -> JSON file`
  - `hbm_receipt_gate(ndiv, timings, force) -> 0 accepted, 1 rejected`
  - `HBM_RECEIPT_FORCED=0|1` set by `hbm_receipt_gate`

- [ ] **Step 1: Add failing tests for canonical identity and missing receipts**

Add cases which invoke a test-only CLI command exposed as `170tune receipt-test` only when `TUNE_TEST_MODE=1`:

```bash
id1=$(run_tune receipt-test id 70 "REFRESH 24 RAS 43")
id2=$(run_tune receipt-test id 70 "ras 43 refresh 24")
[ "$id1" = "$id2" ] || fail "timing order changed profile id"
[[ "$id1" =~ ^[0-9a-f]{16}$ ]] || fail "invalid profile id: $id1"

if run_tune receipt-test validate 70 "REFRESH 24"; then
  fail "missing HBM receipt was accepted"
fi
```

Also assert rejection for an odd timing token count, a nonnumeric value, and an invalid field name.

- [ ] **Step 2: Run tests and witness both failures**

Run:

```bash
bash tests/test_170tune.sh
```

Expected: FAIL because `receipt-test` and HBM receipt validation do not exist.

- [ ] **Step 3: Implement fingerprint and normalization helpers**

Add:

```bash
driver_version() { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' '; }
vbios_version()  { nvidia-smi --query-gpu=vbios_version  --format=csv,noheader 2>/dev/null | head -1 | tr -d ' '; }
```

`normalize_timings` must split pairs, validate field names against `^[A-Z][A-Z0-9_]*$`, validate values against `^[0-9]+$`, uppercase fields, sort complete `FIELD VALUE` records with `LC_ALL=C sort`, and print one space-separated line. Empty input prints an empty line.

`hbm_profile_id` must hash `ndiv=<N>;timings=<NORMALIZED>` with `sha256sum`, falling back to `shasum -a 256`, and print the first 16 characters.

- [ ] **Step 4: Implement JSON receipt creation and validation**

Write receipts beneath `$STATE/gated-hbm/$(serial)/`. Validation must compare every authoritative field rather than trusting the file name:

```text
serial, device_id, driver_version, vbios_version, ndiv, timings,
sweeps, peak_hbm_c, compute_check, context_check, workload,
workload_timeout, workload_rc, gated
```

`hbm_receipt_gate` rejects missing/mismatched receipts, fewer than four sweeps, peak temperature below `GATE_TEMP`, or false compute/context results. It initializes `HBM_RECEIPT_FORCED=0`. With `force=1`, it prints `FORCED HBM persistence`, sets `HBM_RECEIPT_FORCED=1`, and returns success without describing the profile as qualified.

- [ ] **Step 5: Add the guarded receipt-test entry point**

At the CLI dispatch boundary, support:

```bash
receipt-test)
    [ "${TUNE_TEST_MODE:-}" = 1 ] || die "receipt-test is test-only"
    shift
    case "${1:-}" in
      id) shift; hbm_profile_id "${1:?ndiv}" "$(normalize_timings "${2:-}")" ;;
      validate) shift; hbm_receipt_gate "${1:?ndiv}" "${2:-}" 0 ;;
      *) die "usage: receipt-test {id|validate} <ndiv> <timings>" ;;
    esac
    ;;
```

- [ ] **Step 6: Run focused tests and verify green**

Run:

```bash
bash tests/test_170tune.sh
bash -n tools/170tune tests/test_170tune.sh
```

Expected: canonical identity tests pass and missing HBM evidence is rejected by the receipt validator.

- [ ] **Step 7: Commit the receipt model**

```bash
git add tools/170tune tests/test_170tune.sh
git commit -m "feat: add exact HBM qualification receipts"
```

### Task 3: Add the combined `hbm-gate` qualification command

**Files:**
- Modify: `tools/170tune:978-1080,1205-1226,1805-1914,1979-2012`
- Test: `tests/test_170tune.sh`

**Interfaces:**
- Consumes: `_hot_gate_sweeps`, `HBM_MCLK`, `FBPA_REGS`, `SELFTEST`, `COMPUTE`, `CTXPROBE`, `WORKLOAD_TIMEOUT`.
- Produces:
  - `LAST_GATE_PEAK_HBM`, `LAST_GATE_SWEEPS`, `LAST_GATE_COMPUTE_OK`, `LAST_GATE_CONTEXT_OK`
  - `apply_hbm_timings(canonical_timings) -> 0 with readback match`
  - `verify_hbm_profile(ndiv, canonical_timings) -> 0 with PLL/timing readback match`
  - `cmd_hbm_gate --ndiv N [--timings STRING] [--sweeps N] [--workload COMMAND]`

- [ ] **Step 1: Write failing success/failure receipt tests**

Add a successful stubbed gate case:

```bash
run_tune hbm-gate --ndiv 70 --timings "REFRESH 24" --sweeps 4 --workload true
receipt=$(find "$TMP/state/gated-hbm/TESTSERIAL" -name '*.json' -type f)
[ -f "$receipt" ] || fail "successful gate wrote no receipt"
assert_file_contains "$receipt" '"ndiv": 70'
assert_file_contains "$receipt" '"timings": "REFRESH 24"'
assert_file_contains "$receipt" '"workload_rc": 0'
```

Add one case each for `MEM_ERRORS=1`, `COMPUTE_OK=0`, `ctx_rc=2`, workload exit 1, cold peak temperature, timing readback mismatch, and NDIV readback mismatch. Every failure must return nonzero and leave no receipt.

- [ ] **Step 2: Run tests and witness missing-command failure**

Run:

```bash
bash tests/test_170tune.sh
```

Expected: FAIL with the CLI help/unknown-command path because `hbm-gate` is not implemented.

- [ ] **Step 3: Expose hot-gate results without changing existing callers**

Initialize the four `LAST_GATE_*` globals before `_hot_gate_sweeps`. Set them from the actual sweep results and context result. Preserve the existing function return code and console output so `mclk-gate`, `timings-gate`, and `refresh gate` keep their behavior.

- [ ] **Step 4: Implement timing application and exact readback**

`apply_hbm_timings` iterates normalized pairs, calls `fbpa_regs set`, then calls `fbpa_regs get` for the same field and requires decimal equality. `verify_hbm_profile` requires `cur_ndiv` to equal the requested NDIV and repeats timing readback without writing.

- [ ] **Step 5: Implement `cmd_hbm_gate`**

Parse named options only. Require `--ndiv`; default `--timings` to empty and `--sweeps` to 4. Apply timings before increasing NDIV, call `_hot_gate_sweeps`, run the optional workload under `timeout "$WORKLOAD_TIMEOUT" bash -c`, compare Xid counts before and after, call `verify_hbm_profile`, and write the receipt only after every check passes.

On failure, print `HBM PROFILE REJECTED`, call `mclk_revert`, restore stock timings when timings were supplied, and return nonzero.

- [ ] **Step 6: Add CLI help and dispatch**

Document exactly:

```text
hbm-gate --ndiv N [--timings "FIELD VALUE ..."] [--sweeps N]
         [--workload "COMMAND"]
    qualify the exact combined HBM profile and write its per-card receipt
```

Dispatch `hbm-gate` through `need_root` and `cmd_hbm_gate`.

- [ ] **Step 7: Run the complete shell suite and syntax checks**

Run:

```bash
bash tests/test_170tune.sh
bash -n tools/170tune tools/170hx-oc tools/170hx-sweep tools/170hx-soak tests/test_170tune.sh
```

Expected: all gate success/failure cases pass and all scripts parse.

- [ ] **Step 8: Commit the combined gate**

```bash
git add tools/170tune tests/test_170tune.sh
git commit -m "feat: qualify combined HBM profiles"
```

### Task 4: Enforce receipts at save, enable, and boot

**Files:**
- Modify: `tools/170tune:1327-1443`
- Test: `tests/test_170tune.sh`

**Interfaces:**
- Consumes: `hbm_receipt_gate`, `normalize_timings`, `verify_hbm_profile`, `ctx_dead`, `xids`, `mclk_revert`.
- Produces:
  - persisted `HBM_FORCED=0|1`
  - `validate_persisted_hbm(ndiv, timings, forced) -> 0 accepted, 1 rejected`
  - `revert_boot_profile(reason) -> nonzero after stock recovery`

- [ ] **Step 1: Write failing persistence tests**

Add cases proving:

```text
save without receipt -> rejected
save with exact receipt -> accepted with HBM_FORCED=0
save --force without receipt -> accepted with HBM_FORCED=1
save with stale driver/VBIOS/device/serial/NDIV/timings -> rejected
SM-only save -> unchanged
stock-HBM save -> no HBM receipt required
persist enable after manual receipt deletion -> rejected
```

For `persist enable`, use the `systemctl` stub and assert that no `enable` call is logged after validation fails.

- [ ] **Step 2: Run tests and witness current acceptance bugs**

Run:

```bash
bash tests/test_170tune.sh
```

Expected: FAIL because save and enable do not yet enforce HBM evidence or write `HBM_FORCED`.

- [ ] **Step 3: Enforce HBM validation during save**

Normalize timings before writing the config. Treat empty NDIV as stock only when no timings are supplied. For non-stock NDIV or nonempty timings, call `hbm_receipt_gate "$ndiv" "$tim" "$force"`; write `HBM_FORCED=$HBM_RECEIPT_FORCED` so only an actual receipt bypass is marked forced.

- [ ] **Step 4: Revalidate the stored profile during enable**

Load the per-serial configuration, default a missing `HBM_FORCED` to `0`, and call `validate_persisted_hbm` before installing/enabling the systemd unit. Old non-stock HBM configurations without receipts must remain on disk but fail with the exact `hbm-gate` command needed to qualify them.

- [ ] **Step 5: Write failing bounded boot-validation tests**

Add cases for:

```text
missing/stale receipt -> stay stock and return nonzero
timing set/readback mismatch -> invoke mclk_revert and return nonzero
NDIV readback mismatch or PLL failure -> invoke mclk_revert and return nonzero
ctx_rc=2 -> invoke mclk_revert and return nonzero
new Xid count after apply -> invoke mclk_revert and return nonzero
historical Xid count unchanged -> accepted
matching qualified profile -> accepted
forced profile -> accepted but log contains forced
successful boot -> no gpu_selftest invocation
```

- [ ] **Step 6: Run tests and witness the current boot false-positive/false-negative behavior**

Run:

```bash
bash tests/test_170tune.sh
```

Expected: FAIL because current boot checks neither receipts nor context/readback, treats all historical Xids as current failures, and has no forced-profile state.

- [ ] **Step 7: Implement bounded boot validation and stock fallback**

Before applying, validate the receipt unless forced. Capture `xids_before=$(xids)`. Require every timing set/readback, NDIV set/readback, and `ctx_dead` check to pass. Compare `xids_after` to `xids_before`; only a higher count is a new fault. Centralize failure handling:

```bash
revert_boot_profile() {
    local reason=$1
    logger -t 170tune "boot-apply: $reason; reverting to stock"
    "$NVML" 0 0 >/dev/null 2>&1 || true
    nvidia-smi -rgc >/dev/null 2>&1 || true
    mclk_revert
    disarm
    return 1
}
```

Do not invoke `SELFTEST`, `BENCH`, `COMPUTE`, `soak_to_temp`, or an external workload from `boot-apply`.

- [ ] **Step 8: Run persistence and boot tests to verify green**

Run:

```bash
bash tests/test_170tune.sh
bash -n tools/170tune tests/test_170tune.sh
```

Expected: all receipt, save, enable, boot acceptance, and boot rejection cases pass.

- [ ] **Step 9: Commit persistence enforcement**

```bash
git add tools/170tune tests/test_170tune.sh
git commit -m "fix: reject unqualified persisted HBM profiles"
```

### Task 5: Document migration and perform complete verification

**Files:**
- Modify: `README.md:30-39,140-153,188-220`
- Modify: `docs/tuning-guide.md:477-571,559-625`
- Test: `tests/test_170tune.sh`

**Interfaces:**
- Consumes: completed `hbm-gate`, receipt enforcement, and bounded boot behavior.
- Produces: user-facing commands that match the implemented CLI exactly.

- [ ] **Step 1: Write documentation examples against the implemented CLI**

Replace direct HBM persistence examples with:

```bash
sudo WORKLOAD_TIMEOUT=28800 170tune hbm-gate \
  --ndiv 70 \
  --timings "REFRESH 24" \
  --sweeps 12 \
  --workload "/path/to/the/real/serving-soak.sh"
sudo 170tune persist save --ndiv 70 --timings "REFRESH 24"
sudo 170tune persist enable
```

Document that existing non-stock HBM profiles require requalification after upgrade, `--force` records an unqualified override, driver/VBIOS changes invalidate receipts, and boot performs no hot/full-VRAM retest.

- [ ] **Step 2: Verify documentation command names against help output**

Run:

```bash
bash tools/170tune --help | grep -F 'hbm-gate --ndiv N'
rg -n 'persist save --ndiv' README.md docs/tuning-guide.md
```

Expected: every production persistence example is preceded by the matching `hbm-gate` flow or clearly marked as forced/unqualified.

- [ ] **Step 3: Run the full fresh verification set**

Run:

```bash
bash tests/test_170tune.sh
bash -n tools/170tune tools/170hx-oc tools/170hx-sweep tools/170hx-soak \
  tools/setup-vllm-170hx.sh tools/vllm_workload_check.sh tests/test_170tune.sh
git diff --check origin/main...HEAD
git status --short
```

Expected: test suite reports zero failures; every shell file parses; `git diff --check` is silent; only intentional tracked changes are present.

- [ ] **Step 4: Review the requirement checklist**

Confirm from code and tests:

```text
exact combined HBM profile receipt
per-card and environment fingerprint
four-sweep/hot/compute/context enforcement
explicit forced override marker
save and enable validation
bounded boot readback/context/new-Xid checks
stock fallback on boot failure
no full-VRAM boot test
SM-only and stock-HBM compatibility
migration message for old profiles
```

- [ ] **Step 5: Commit documentation**

```bash
git add README.md docs/tuning-guide.md
git commit -m "docs: require HBM qualification before persistence"
```

- [ ] **Step 6: Request independent code review**

Dispatch one reviewer with the base SHA `9d680b8` and the final HEAD. Require review of receipt matching, shell quoting, forced-mode semantics, boot failure recovery, test realism, and compatibility. Fix every Critical or Important finding and reuse the same reviewer for re-review.

- [ ] **Step 7: Re-run verification after review fixes**

Repeat Step 3 after the final review change. Do not push until this fresh run is green.

- [ ] **Step 8: Push the reviewed branch**

```bash
git push origin fix/hbm-persistence-safety
```

Expected: `origin/fix/hbm-persistence-safety` points to the fully reviewed and verified HEAD; `main` remains unchanged.
