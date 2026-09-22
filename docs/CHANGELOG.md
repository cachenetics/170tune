# Changelog

Dated history of the findings, corrections, and retractions behind the current docs. The
reference and teaching documents state current truth only; the path that led there,
including the conclusions that turned out to be wrong, is recorded here so no dead end
gets walked twice.

## 2026-09-22: the STOCK_NDIV fix below undersold the problem - now auto-detected

- Follow-up to the STOCK_NDIV entry below, same day: the operator pointed out 170tune
  officially supports BOTH the 8GB (0x20C2) and 10GB (0x2082) 170HX, which prompted
  actually checking whether meatsus's NDIV 54 was a one-off VBIOS oddity or something
  systematic. It is systematic, and already documented in this repo's sibling:
  cmpunlocker's `overclocking/README.md` measures THREE real stock points, not one -
  10GB any-wattage at NDIV 45/1215MHz, 8GB 250W-vbios at NDIV 54/1458MHz, 8GB 300W-vbios
  at NDIV 64/1728MHz (this tool's compiled reference). The two 8GB variants are not
  distinguishable from the PCI device id alone; the 10GB one is.
- So the previous fix (name the STOCK_NDIV override at the point of failure) was correct
  but incomplete: it turned a silent catch-22 into a documented manual step, for a
  situation that is not an edge case - it is the default experience for every 10GB
  card and every 250W-vbios 8GB card on first run.
- Fixed properly: `known_stock_ndivs()` returns the legitimate stock set for the
  detected device id; `load_stock_override()` now checks the live clock against that
  set (when no per-card snapshot exists yet) and adopts it automatically, no env var or
  snapshot-stock run required. The STOCK_NDIV override from the prior entry remains as
  the fallback for a genuinely fourth/uncatalogued variant - the auto-detect only covers
  the three documented points, on purpose, so a real bake/tune (or a real unknown) still
  refuses rather than being silently waved through.
- Two of the four STOCK_NDIV tests from the prior entry were repointed at an explicitly
  uncatalogued NDIV (58) so they keep testing the fallback path instead of accidentally
  testing the now-auto-detected 54 case; two new tests cover the 54 and 45 auto-detect
  paths directly. 37 tests in test_170tune.sh, all green.

## 2026-09-22: 170hx-oc silently reported a dropped VF-offset write as applied

- Same live triage as the STOCK_NDIV entry below, next report from the same card: `170hx-oc
  custom 250 1400` printed `power limit 300 W REFUSED` and `clock ceiling 1400 REFUSED` (both
  correct - nvidia-smi's own exit code), but no offset warning at all, and the summary line
  quietly showed `offset=+0` where +250 was requested.
- Root cause: `nvmlDeviceSetGpcClkVfOffset` can return `NVML_SUCCESS` while the driver drops the
  write outright - `nvml_oc.c` already detects this via readback and prints an explicit WARNING,
  but 170hx-oc called it with `>/dev/null 2>&1` and branched on ITS EXIT CODE, which is always 0
  regardless. The `|| echo "... offset REFUSED"` on that line was dead code - it could not fire.
  A card whose power limit is well under the 300 W reference (this one reported 150 W) is enough
  to make the driver refuse the offset outright, silently.
- Fixed: 170hx-oc already computed the readback one line later (for the summary) - moved the
  REFUSED check to compare that readback against the requested offset instead of trusting
  nvml_oc's exit code. Caught one bug while fixing this one: the readback prints signed
  (`+250`), the requested value never carries a sign, so a naive `=` comparison flagged every
  SUCCESSFUL apply as refused - fixed by stripping the sign before comparing. Manually verified
  both directions (dropped and applied) plus a garbled-readback case before trusting it, then
  added `tests/test_170hx_oc.sh` (stubbed nvidia-smi/nvml_oc, no hardware) so this stays pinned;
  wired into `.gitlab-ci.yml`'s lint job.
- 170hx-oc has no OTHER behavioral test coverage - lint (`bash -n` + shellcheck) is all it had
  before this. Flagging, not fixing further here: the power-limit ceiling itself (150 W on this
  card vs. the 300 W reference) is very likely a VBIOS power-management-table value, a different
  axis entirely from what cmpunlocker's driver patches (BAR1/ECC/HBM-PLL) touch - raising it
  needs a modified VBIOS, not a 170tune change. Out of scope here.

## 2026-09-22: STOCK_NDIV catch-22 on a non-reference card

- A community 170HX (device id `0x20C2`, 8GB) genuinely stocks at NDIV 54 (1458 MHz), not
  the hardcoded reference NDIV 64 (1728 MHz) `mclk_source()` assumes. Preflight, live off
  a plain no-`--mclk-ndiv` driver, correctly read NDIV 54 off the register (BAR0, matching
  nvidia-smi exactly) but misreported it as `driver-baked` - the check has no way to tell
  "someone baked a custom clock" apart from "this card's own VBIOS stock differs from the
  one card 170tune was measured on." `snapshot-stock`, the tool's own designed fix for a
  per-card stock reference, refused for the same reason it exists to fix: it also gates on
  `mclk_source() != driver-baked`, so a card in this state had no documented way in.
- The escape hatch already existed (`STOCK_NDIV` env var, read at the top of the script)
  but was invisible - nothing printed by preflight, `snapshot-stock`, or `explain-hbm`
  mentioned it, so the only way to find it was to read the shell source directly.
- Fixed: the three refusal sites (preflight's FAIL block, `refuse_if_mclk_baked`,
  `snapshot-stock`'s poisoned-reference guard) now name the override inline
  (`STOCK_NDIV=<value> 170tune snapshot-stock`) and point at `hbm_mclk get` to find the
  real value. No behavior change for a genuinely driver-baked card - it still refuses the
  same way, just with a way out documented for the case that isn't that.
- Not (yet) fixed: 170tune still has exactly one hardcoded reference card. A fleet with
  multiple stock NDIVs works fine per-card once each has run `snapshot-stock` once, but
  there is still no way to know a card's true stock NDIV other than reading it live off an
  unmodified driver - if a user's driver was ALREADY non-stock on first install, the tool
  cannot tell that apart from a legitimately different-stock card either. Out of scope
  here; flagging so it isn't rediscovered as a surprise.

## 2026-08-30: documentation consolidation

- All measured tables moved to a single home, `docs/reference-matrices.md`;
  `docs/measurement-matrix.md` and `docs/hbm-matrix.md` are merged into it (and into
  `docs/hbm-timing-understanding.md`) and removed.
- `docs/hbm-timing-understanding.md` rewritten ground-up as a teaching document; the lab
  chronology and in-line retractions it carried moved here.
- The FWSEC BAR0 aperture notes (Gen3 link-training background, unrelated to tuning)
  removed from the tuning guide; that material lives with the link-training project.

## 2026-08: SM serving qualification, and the profiles it quarantined

- Long-soak serving qualification (vLLM, long-context prompts, multi-step generations)
  found that offsets of +300 and +350 fault in service on the reference card: +300/1350
  passed a 4/4 hot gate, passed a real-workload rung, served a full day of benchmarks,
  then faulted with Xid 13 on the weak SMs (GPC3/TPC6) under an hour-long soak. +300
  faulted at every ceiling tested (1350/1400/1470/1650); +350 at 1590/1650.
- Consequence: the named profiles eff (+300), balanced (+300), perf (+350), and max
  (+350) are reclassified as bench-only. The serving-qualified offsets are +200 and
  +250. The lesson: the risk lever is voltage-at-frequency, not offset or clock alone,
  and a GEMM matrix cell does not predict whether a point can serve.
- Independently re-confirmed at a capped operating point: under a live 200 W power cap,
  +250 and +265 stayed clean; +280 and +290 threw Xid 13 then Xid 43.

## 2026-08-05: persistence unified; the per-profile boot unit retired

- The old per-profile `170hx-oc.service` unit (`ExecStart=170hx-oc eff`) is retired: it
  covered only the SM profile, could not express an HBM point, and would have raced the
  newer HBM persistence at boot.
- Persistence is now unified in `170tune persist`: one conf per serial, one generated
  systemd unit, applied by `170tune boot-apply` after the driver is up. Saves are
  receipt-gated; a receipt binds card serial, PCI device ID, driver, and VBIOS, and a
  driver or VBIOS change invalidates it. `170tune install` migrates a box still on the
  old unit automatically and loudly.

## 2026-08-04: the serving ceiling is not the pattern-sweep ceiling

- A real inference workload proved harsher than the hot pattern sweep on the memory side:
  NDIV 72 (gated 12/12) corrupts as serving drives the HBM past ~75 C and wedges uncooled
  at 90 C; NDIV 74-76 crash outright. NDIV 76 failed on the very first serving load even
  started cool at 56 C: a temperature-independent read-eye wall against the serving
  access pattern. The serving ceiling is NDIV 70.
- The MR2 read-latency lever for the NDIV 76 eye wall was tested and ruled out: RL raised
  29 to 31 (the 5-bit field maximum) plus tCL 37 to 39 plus a DDLL recalibration still
  crashed identically. Holding stock read latency in ns at 2052 MHz needs ~34 cycles, so
  the wall is field width, not calibration. (One unexplored thread: whether byte 2 of the
  MR2 shadow holds extended RL bits; each probe costs a wedge, so it is parked.)
- Two operational rules established: never change NDIV under an active CUDA context (it
  wedges the GPU, Xid 45/119, power cycle), and keep the GPU fan driven by HBM
  temperature whenever the card serves.
- Refresh characterized under serving at stock clock: flat on decode and temperature,
  safe even very loose (REFRESH 192, ~30x JEDEC, zero corruption), worth only ~2.5
  percent of board power under load. Refresh is an idle-power lever, not a serving lever;
  it had only looked dangerous when stacked on an overclocked memory point.

## 2026-08-03: HBM corrections and retractions

- **"Memory overclock is closed" retracted: we had been measuring the wrong write.**
  Earlier docs concluded from the driver's NVML `MEM clock VF offset [0..0]` refusal, and
  from up-clock attempts that delivered nothing, that the memory clock was clamped. The
  NVML path really is closed, but it was the wrong write: the memory clock has its own
  PLL, reachable live over BAR0, and it moves in both directions once the write lands
  correctly (post-GSP, multicast to all FBPAs, PRI fence, PLL-lock poll). The proof is
  bandwidth above the stock clock's theoretical ceiling. `nvidia-smi` is blind to this
  class of write and reports stock at every NDIV.
- **"NDIV 77 is robust (15/15)" retracted: it was a cooler, luckier run.** A proper hot
  gate on a fresh boot gave bare NDIV 76 = 12/12 but command-tuned 77 = 11/12 failing at
  64-66 C, clean only at or below ~61 C. The mechanism is retention (temperature-
  dependent cell leakage), and holding 77 hot with tighter refresh costs more bandwidth
  than the clock gains. Bare 76 is the honest pattern-sweep ceiling.
- **The DDLL eye-recalibration chase was a red herring for 77.** Its apparent
  contribution was noise; it is non-deterministic and off every ship path. The eye-lever
  framing remains correct only for a genuinely eye-limited clock (78 is; see 2026-08-04
  for 76 under serving).
- **Two phantom results corrected:** "DDLL recal lifts the ceiling 70 to 75" was a broken
  gate wrapper (a selftest run under sudo resolved `~` to /root and never ran, defaulting
  every sweep to failed); "read plateaus at 1871 from NDIV 73" was depressed by
  concurrent power sampling during the bench. Clean measurement climbs monotonically to
  76.

## Earlier

- The `eff` profile briefly shipped at +400/1350 on the strength of two clean sweeps; a
  later sweep returned `mem_errors=1`. Two policies date from this: ship the lowest
  offset that reaches the voltage floor, never the highest that appears to work, and
  never call two clean sweeps a gate for an intermittent failure mode (the gate default
  is four or more, hot).
