/*
 * idle_policy.h - the decisions behind idle_power, kept free of NVML and BAR0 so they can be
 * unit-tested (tests/idle_policy_test.c) the way resident_sweep.h is.
 *
 * A 170HX has one performance state, so the driver never lowers the HBM clock and holds the SM at
 * 1140 MHz whenever a CUDA context exists. idle_power emulates an idle state instead:
 *
 *   busy  the card's own profile: busy_ndiv / busy_refresh (what boot-apply set - the persisted
 *         HBM profile, or stock) and the SM window 210..busy_clk (the persisted ceiling, or no lock)
 *   idle  HBM at idle_ndiv and the SM locked to idle_clk
 *
 * Independently of busy/idle, the refresh interval is loosened while the HBM is cool - to
 * cool_refresh, or to the looser idle_refresh while the card is also idle - and put back to
 * busy_refresh once it is hot. Retention is temperature-dependent and a gate
 * receipt only proves a point up to the HBM temperature it reached, so cool_c is that peak. The
 * idle downclock obeys the same ceiling. hot_c > cool_c is the hysteresis band: between the two,
 * whatever is set stays set.
 */
#ifndef IDLE_POLICY_H
#define IDLE_POLICY_H

struct idle_cfg {
    int hbm;            /* 1: this card has idle-gate receipts, so HBM may be touched */
    int busy_ndiv, idle_ndiv;
    int busy_refresh, cool_refresh, idle_refresh;
    int cool_c, hot_c;  /* at or below cool_c: loosen/downclock; at or above hot_c: back off */
    int busy_clk;       /* SM ceiling while busy; 0 = no lock (reset) */
    int idle_clk;
};

static inline int idle_is_cool(const struct idle_cfg *c, int hbm_c) { return hbm_c <= c->cool_c; }
static inline int idle_is_hot(const struct idle_cfg *c, int hbm_c)  { return hbm_c >= c->hot_c; }

/* NDIV the card should be at, given its state and HBM temperature. cur_ndiv supplies the
 * hysteresis: an idle card already downclocked stays there until hot, one at busy_ndiv only
 * drops once cool. */
static inline int idle_ndiv_target(const struct idle_cfg *c, int idle, int cur_ndiv, int hbm_c)
{
    if (!c->hbm || !idle) return c->busy_ndiv;
    if (cur_ndiv == c->idle_ndiv) return idle_is_hot(c, hbm_c) ? c->busy_ndiv : c->idle_ndiv;
    return idle_is_cool(c, hbm_c) ? c->idle_ndiv : c->busy_ndiv;
}

/* Refresh field the card should be at: loosened only while cool - idle_refresh when idle,
 * cool_refresh when busy - and busy_refresh once hot. A card already loosened stays loose
 * through the hysteresis band; a tight one only loosens once cool. */
static inline int idle_refresh_target(const struct idle_cfg *c, int idle, int cur_refresh, int hbm_c)
{
    int loose = idle ? c->idle_refresh : c->cool_refresh;
    if (!c->hbm) return c->busy_refresh;
    if (cur_refresh == c->cool_refresh || cur_refresh == c->idle_refresh)
        return idle_is_hot(c, hbm_c) ? c->busy_refresh : loose;
    return idle_is_cool(c, hbm_c) ? loose : c->busy_refresh;
}

/* Is there work on the card? Utilization is averaged over up to a second, so an idle card also
 * counts as busy the moment its draw rises busy_delta_w above the draw it settled at when it went
 * idle (the power sensor reacts in ~20 ms). idle_baseline_w <= 0 means no baseline yet. */
static inline int idle_activity(unsigned util_gpu, unsigned util_mem, int idle,
                                double power_w, double idle_baseline_w, double busy_delta_w)
{
    if (util_gpu > 0 || util_mem > 0) return 1;
    return idle && idle_baseline_w > 0 && power_w > idle_baseline_w + busy_delta_w;
}

/* The next busy/idle state: wake at once on activity, go idle only after quiet_s >= idle_after_s. */
static inline int idle_next_state(int idle, int active, double quiet_s, double idle_after_s)
{
    if (active) return 0;
    return idle || quiet_s >= idle_after_s;
}

#endif
