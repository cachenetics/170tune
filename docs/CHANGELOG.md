# Changelog

Dated history of the findings, corrections, and retractions behind the current docs. The
reference and teaching documents state current truth only; the path that led there,
including the conclusions that turned out to be wrong, is recorded here so no dead end
gets walked twice.

## 2026-08-30: documentation consolidation

- All measured tables moved to a single home, `docs/reference-matrices.md`;
  `docs/measurement-matrix.md` is merged into it and removed.
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
