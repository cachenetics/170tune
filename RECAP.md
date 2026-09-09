# RECAP - 170tune (proj 63)

updated:  2026-09-09
branch:   main @ fcac996
state:    clean, no open MRs/issues; README rewritten as an OEM-grade manual, serving default is SM +250 / HBM NDIV 70 / REFRESH 24, multi-GPU selector and PLL PRI-error preflight check both landed; a dozen old feature branches (github + LAN GitLab) sit stale/superseded on the remote with no open MR, their content already in main under different commit hashes - not in-flight work
next:     none pending - repo is at rest; next real step is qualifying a new operating point on hardware (hbm-matrix / hbm-gate) rather than a code change
blocked:  none
settled:  serving default SM offset +250 (not +300/+350, which fault Xid 13 under long soak - quarantined bench-only); HBM serving ceiling NDIV 70 (72 corrupts hot, 74-76 crash, 76 is a field-width eye wall not thermal); REFRESH 24 for serving; 175 W is the sustained-delivery efficiency knee; persistence is receipt-gated per card serial and self-disarms on an unchecked-in boot; unicast FBPA0 PLL unlock (cmpunlocker lineage) is required for the live HBM lever, broadcast-only unlocks are not compatible; "it did not crash" is not a qualification result, only the hot full-VRAM + compute-check gate qualifies a point
docs:     README.md is the entry point; docs/tuning-guide.md (manual), docs/reference-matrices.md (measured tables), docs/CHANGELOG.md (dated history/retractions) are the living record
tests:    bash tests/test_170tune.sh && bash tests/test_hbm_test_step.sh (also run by .gitlab-ci.yml `lint`/`build` stages); this is a static/build smoke gate only, it never touches hardware - the real correctness proof is the on-card hot gate (170tune preflight/snapshot-stock/mclk-gate/persist across a reboot)
