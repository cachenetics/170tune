#include "../tools/idle_policy.h"

#include <stdio.h>

static int failures;

#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static const struct idle_cfg gated = {
    .hbm = 1, .busy_ndiv = 64, .idle_ndiv = 30, .busy_refresh = 6, .cool_refresh = 24, .idle_refresh = 48,
    .cool_c = 60, .hot_c = 63, .busy_clk = 1400, .idle_clk = 210,
};

static void busy_card_always_runs_its_own_profile(void)
{
    CHECK(idle_ndiv_target(&gated, 0, 30, 40) == 64);
    CHECK(idle_ndiv_target(&gated, 0, 64, 40) == 64);
}

static void idle_downclock_obeys_the_gated_temperature(void)
{
    CHECK(idle_ndiv_target(&gated, 1, 64, 55) == 30);   /* cool: drop */
    CHECK(idle_ndiv_target(&gated, 1, 64, 61) == 64);   /* in the band, not yet down: stay up */
    CHECK(idle_ndiv_target(&gated, 1, 30, 62) == 30);   /* in the band, already down: stay down */
    CHECK(idle_ndiv_target(&gated, 1, 30, 63) == 64);   /* hot: back to the busy clock */
}

static void refresh_is_loose_only_while_cool(void)
{
    CHECK(idle_refresh_target(&gated, 0, 6, 60) == 24);
    CHECK(idle_refresh_target(&gated, 0, 6, 61) == 6);
    CHECK(idle_refresh_target(&gated, 0, 24, 62) == 24);
    CHECK(idle_refresh_target(&gated, 0, 24, 63) == 6);
}

static void idle_cool_card_takes_the_deeper_refresh(void)
{
    CHECK(idle_refresh_target(&gated, 1, 6, 55) == 48);    /* idle and cool: deepest */
    CHECK(idle_refresh_target(&gated, 1, 24, 62) == 48);   /* already loose: band keeps it loose */
    CHECK(idle_refresh_target(&gated, 0, 48, 55) == 24);   /* woke up: back to the busy-cool field */
    CHECK(idle_refresh_target(&gated, 1, 48, 63) == 6);    /* hot: stock-side */
}

static void without_a_deep_receipt_idle_refresh_equals_cool_refresh(void)
{
    struct idle_cfg shallow = gated;
    shallow.idle_refresh = shallow.cool_refresh;
    CHECK(idle_refresh_target(&shallow, 1, 6, 55) == 24);
    CHECK(idle_refresh_target(&shallow, 1, 24, 62) == 24);
}

static void ungated_card_never_touches_hbm(void)
{
    struct idle_cfg sm_only = gated;
    sm_only.hbm = 0;
    CHECK(idle_ndiv_target(&sm_only, 1, 64, 20) == 64);
    CHECK(idle_refresh_target(&sm_only, 1, 6, 20) == 6);
}

static void activity_wakes_on_utilization_or_a_power_step(void)
{
    CHECK(idle_activity(1, 0, 1, 30.0, 30.0, 12.0));
    CHECK(idle_activity(0, 3, 0, 40.0, 0.0, 12.0));
    CHECK(!idle_activity(0, 0, 1, 41.9, 30.0, 12.0));
    CHECK(idle_activity(0, 0, 1, 42.1, 30.0, 12.0));
    CHECK(!idle_activity(0, 0, 1, 99.0, 0.0, 12.0));    /* no baseline yet: utilization only */
    CHECK(!idle_activity(0, 0, 0, 99.0, 30.0, 12.0));   /* power step only counts while idle */
}

static void state_goes_idle_after_the_quiet_period_and_wakes_at_once(void)
{
    CHECK(idle_next_state(0, 0, 4.9, 5.0) == 0);
    CHECK(idle_next_state(0, 0, 5.0, 5.0) == 1);
    CHECK(idle_next_state(1, 0, 0.0, 5.0) == 1);
    CHECK(idle_next_state(1, 1, 99.0, 5.0) == 0);
}

int main(void)
{
    busy_card_always_runs_its_own_profile();
    idle_downclock_obeys_the_gated_temperature();
    refresh_is_loose_only_while_cool();
    idle_cool_card_takes_the_deeper_refresh();
    without_a_deep_receipt_idle_refresh_equals_cool_refresh();
    ungated_card_never_touches_hbm();
    activity_wakes_on_utilization_or_a_power_step();
    state_goes_idle_after_the_quiet_period_and_wakes_at_once();
    if (failures) return 1;
    printf("idle_policy_test: all checks passed\n");
    return 0;
}
