/*
 * idle_power - give a CMP 170HX an idle state it does not have (see idle_policy.h for the model).
 *
 * Measured on two 0x20C2 cards (NDIV 64 stock) with an inference server resident and idle:
 * ~41 W -> ~29 W per card. HBM refresh and clock are most of the idle floor; locking the SM low
 * alone buys only ~2.6 W. The first request after an idle period pays the wake-up (~50-80 ms).
 *
 * Opt-in and per card: it manages only the cards '170tune idle enable' wrote a conf for, under
 * $IDLE_DIR/<serial>.conf. HBM is touched only on a card whose conf says HBM=1, which enable
 * writes only when the card holds both idle-gate receipts ('170tune idle gate') for this driver
 * and VBIOS; the driver/VBIOS are re-checked here at start, so an upgrade drops that card to
 * SM-only instead of trusting a stale proof. The register writes go through 170tune's own
 * hbm_mclk / fbpa_regs, so the PLL sequence and its lock guard live in one place.
 *
 * Safety: a new Xid on a card, a failed PLL lock or a refresh readback mismatch disarms that card
 * (back to its busy profile, then left alone until restart). $RUN_DIR/pause, or pause-<serial>
 * for one card, hands cards back to their busy profile and stops touching them - 170tune creates
 * the per-card one around every mutating command. SIGTERM restores every card's busy profile.
 *
 * Build: gcc -O2 -o idle_power idle_power.c -lnvidia-ml   (plus -I<cuda>/include for nvml.h)
 */
#define _GNU_SOURCE
#include "idle_policy.h"

#include <ctype.h>
#include <errno.h>
#include <nvml.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_CARDS     16
#define MIN_CLK       210
#define POLL_MS       100
#define TEMP_EVERY_S  1.0
#define CHECK_EVERY_S 30.0
#define SETTLE_S      2.0      /* idle draw is sampled this long after going idle */
#define TOOL_TIMEOUT  10

struct card {
    char serial[64], bdf[32];
    nvmlDevice_t dev;
    struct idle_cfg cfg;
    int idle, paused, disarmed;
    int ndiv, refresh, hbm_c;
    double last_active, idle_since, baseline_w;
    unsigned xids0;
};

static struct card cards[MAX_CARDS];
static int ncards;
static int group = 0;
static double idle_after = 60.0, busy_delta_w = 12.0;
static const char *idle_dir, *run_dir, *hbm_mclk, *fbpa_regs;
static volatile sig_atomic_t stop;

static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *env_or(const char *k, const char *def)
{
    const char *v = getenv(k);
    return (v && *v) ? v : def;
}

/* Run a helper, capture stdout, enforce a timeout. Returns its exit code, or -1. */
static int run_tool(char *const argv[], char *out, size_t outsz)
{
    int pfd[2], status = 0;
    pid_t pid;
    size_t n = 0;
    ssize_t r;

    if (out && outsz) out[0] = '\0';
    if (pipe(pfd) != 0) return -1;
    pid = fork();
    if (pid < 0) { close(pfd[0]); close(pfd[1]); return -1; }
    if (pid == 0) {
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[0]); close(pfd[1]);
        alarm(TOOL_TIMEOUT);
        execv(argv[0], argv);
        _exit(127);
    }
    close(pfd[1]);
    while (out && n + 1 < outsz && (r = read(pfd[0], out + n, outsz - 1 - n)) > 0) n += (size_t)r;
    if (out && outsz) out[n] = '\0';
    close(pfd[0]);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) ;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int read_ndiv(struct card *c)
{
    char out[256], *p;
    char *argv[] = { (char *)hbm_mclk, "-b", c->bdf, "get", NULL };
    if (run_tool(argv, out, sizeof(out)) != 0 || !(p = strstr(out, "NDIV "))) return -1;
    return atoi(p + 5);
}

static int read_refresh(struct card *c)
{
    char out[64];
    char *argv[] = { (char *)fbpa_regs, "-b", c->bdf, "get", "REFRESH", NULL };
    if (run_tool(argv, out, sizeof(out)) != 0 || !isdigit((unsigned char)out[0])) return -1;
    return atoi(out);
}

static int set_ndiv(struct card *c, int ndiv)
{
    char v[16];
    char *argv[] = { (char *)hbm_mclk, "-b", c->bdf, "set", v, NULL };
    int rc;
    snprintf(v, sizeof(v), "%d", ndiv);
    rc = run_tool(argv, NULL, 0);
    if (rc == 0) c->ndiv = ndiv;
    else logf_("%s: hbm_mclk set %d failed (rc %d)", c->serial, ndiv, rc);
    return rc == 0;
}

static int set_refresh(struct card *c, int field)
{
    char v[16];
    char *argv[] = { (char *)fbpa_regs, "-b", c->bdf, "set", "REFRESH", v, NULL };
    snprintf(v, sizeof(v), "%d", field);
    run_tool(argv, NULL, 0);
    c->refresh = read_refresh(c);
    if (c->refresh != field) logf_("%s: REFRESH %d reads back %d", c->serial, field, c->refresh);
    return c->refresh == field;
}

static void lock_clocks(struct card *c, int idle)
{
    nvmlReturn_t r;
    if (idle) r = nvmlDeviceSetGpuLockedClocks(c->dev, MIN_CLK, c->cfg.idle_clk);
    else if (c->cfg.busy_clk > 0) r = nvmlDeviceSetGpuLockedClocks(c->dev, MIN_CLK, c->cfg.busy_clk);
    else r = nvmlDeviceResetGpuLockedClocks(c->dev);
    if (r != NVML_SUCCESS) logf_("%s: clock lock: %s", c->serial, nvmlErrorString(r));
}

/* Put a card back on its busy profile (best effort, every step attempted). */
static void restore_busy(struct card *c)
{
    if (c->cfg.hbm && c->ndiv >= 0 && c->refresh >= 0) {
        if (c->ndiv != c->cfg.busy_ndiv) set_ndiv(c, c->cfg.busy_ndiv);
        if (c->refresh != c->cfg.busy_refresh) set_refresh(c, c->cfg.busy_refresh);
    }
    lock_clocks(c, 0);
    c->idle = 0;
}

static void disarm(struct card *c, const char *why)
{
    if (c->disarmed) return;
    logf_("%s: DISARMED (%s) - back on its busy profile, left alone until restart", c->serial, why);
    restore_busy(c);
    c->disarmed = 1;
}

static void apply_hbm(struct card *c)
{
    int t;
    if (!c->cfg.hbm || c->disarmed || c->paused) return;
    if (c->ndiv < 0 || c->refresh < 0) return;      /* not readable (yet): leave HBM alone */
    t = idle_ndiv_target(&c->cfg, c->idle, c->ndiv, c->hbm_c);
    if (t != c->ndiv && !set_ndiv(c, t)) { disarm(c, "PLL did not lock"); return; }
    t = idle_refresh_target(&c->cfg, c->idle, c->refresh, c->hbm_c);
    if (t != c->refresh && !set_refresh(c, t)) disarm(c, "refresh readback mismatch");
}

static void set_state(struct card *c, int idle, double t)
{
    if (c->idle == idle) return;
    c->idle = idle;
    if (idle) { c->idle_since = t; c->baseline_w = 0; }
    apply_hbm(c);            /* on the way up, memory first: it carries the bandwidth */
    lock_clocks(c, idle);
    logf_("%s: -> %s", c->serial, idle ? "idle" : "busy");
}

static int hbm_temp(struct card *c)
{
    nvmlFieldValue_t fv;
    memset(&fv, 0, sizeof(fv));
    fv.fieldId = NVML_FI_DEV_MEMORY_TEMP;
    if (nvmlDeviceGetFieldValues(c->dev, 1, &fv) != NVML_SUCCESS || fv.nvmlReturn != NVML_SUCCESS)
        return 99;           /* unreadable counts as hot: stock-side settings */
    switch (fv.valueType) {
    case NVML_VALUE_TYPE_UNSIGNED_INT:       return (int)fv.value.uiVal;
    case NVML_VALUE_TYPE_UNSIGNED_LONG:      return (int)fv.value.ulVal;
    case NVML_VALUE_TYPE_UNSIGNED_LONG_LONG: return (int)fv.value.ullVal;
    case NVML_VALUE_TYPE_SIGNED_LONG_LONG:   return (int)fv.value.sllVal;
    default:                                 return 99;
    }
}

static double power_w(struct card *c)
{
    unsigned mw = 0;
    return nvmlDeviceGetPowerUsage(c->dev, &mw) == NVML_SUCCESS ? mw / 1000.0 : 0;
}

/* <bus>:<dev> of a PCI address in any of the forms NVRM and NVML print (0000:07:00.0, 0000:07:00,
 * 07:00), lowercased - the key 170tune's xids() compares on. */
static void bus_dev(const char *addr, size_t len, char *out, size_t outsz)
{
    char buf[64], *last, *prev;
    snprintf(buf, sizeof(buf), "%.*s", (int)len, addr);
    if ((last = strrchr(buf, '.')) && strchr(last, ':') == NULL) *last = '\0';   /* drop .func */
    last = strrchr(buf, ':');
    if (last) { *last = '\0'; prev = strrchr(buf, ':'); *last = ':'; }
    else prev = NULL;
    snprintf(out, outsz, "%s", prev ? prev + 1 : buf);
    for (char *p = out; *p; p++) *p = (char)tolower((unsigned char)*p);
}

/* Xid / reset lines for this card. Same rule as 170tune's xids(): a line tagged with another
 * card's PCI address is skipped, an untagged one always counts (never blind to a real fault). */
static unsigned count_xids(const struct card *c)
{
    char line[512], want[64], got[64];
    unsigned n = 0;
    FILE *f = popen("dmesg 2>/dev/null", "r");
    if (!f) return 0;
    bus_dev(c->bdf, strlen(c->bdf), want, sizeof(want));
    while (fgets(line, sizeof(line), f)) {
        char *tag;
        if (!strstr(line, "requires reset") && !strstr(line, "Xid ")) continue;
        if ((tag = strstr(line, "PCI:"))) {
            tag += 4;
            bus_dev(tag, strspn(tag, "0123456789abcdefABCDEF:."), got, sizeof(got));
            if (strcmp(got, want) != 0) continue;
        }
        n++;
    }
    pclose(f);
    return n;
}

static int paused_by_file(const struct card *c)
{
    char path[4096];
    struct stat st;
    snprintf(path, sizeof(path), "%s/pause", run_dir);
    if (stat(path, &st) == 0) return 1;
    snprintf(path, sizeof(path), "%s/pause-%s", run_dir, c->serial);
    return stat(path, &st) == 0;
}

static void write_status(void)
{
    char path[4096], tmp[4100];
    FILE *f;
    snprintf(path, sizeof(path), "%s/state.json", run_dir);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    if (!(f = fopen(tmp, "w"))) return;
    fprintf(f, "{\"group\": %d, \"cards\": [", group);
    for (int i = 0; i < ncards; i++) {
        struct card *c = &cards[i];
        fprintf(f, "%s\n {\"serial\": \"%s\", \"bdf\": \"%s\", \"state\": \"%s\", \"hbm\": %d, "
                   "\"ndiv\": %d, \"refresh\": %d, \"hbm_c\": %d, \"power_w\": %.1f}",
                i ? "," : "", c->serial, c->bdf,
                c->disarmed ? "disarmed" : c->paused ? "paused" : c->idle ? "idle" : "busy",
                c->cfg.hbm && !c->disarmed, c->ndiv, c->refresh, c->hbm_c, power_w(c));
    }
    fprintf(f, "\n]}\n");
    fclose(f);
    rename(tmp, path);
}

/* KEY=VALUE conf reader; unknown keys are ignored, a missing required key fails the card. */
static int conf_get(const char *file, const char *key, char *val, size_t valsz)
{
    char line[256];
    size_t kl = strlen(key);
    FILE *f = fopen(file, "r");
    if (!f) return 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, kl) == 0 && line[kl] == '=') {
            char *v = line + kl + 1;
            v[strcspn(v, "\r\n")] = '\0';
            if (*v == '"') { v++; v[strcspn(v, "\"")] = '\0'; }
            snprintf(val, valsz, "%s", v);
            fclose(f);
            return 1;
        }
    }
    fclose(f);
    return 0;
}

static int conf_int(const char *file, const char *key, int *out)
{
    char v[64], *end;
    long n;
    if (!conf_get(file, key, v, sizeof(v))) return 0;
    n = strtol(v, &end, 10);
    if (end == v || *end) return 0;
    *out = (int)n;
    return 1;
}

static int load_card_cfg(struct card *c, const char *file)
{
    struct idle_cfg *g = &c->cfg;
    char want[96], have[96];
    if (!conf_int(file, "HBM", &g->hbm) || !conf_int(file, "BUSY_CLK", &g->busy_clk) ||
        !conf_int(file, "IDLE_CLK", &g->idle_clk) || !conf_int(file, "BUSY_NDIV", &g->busy_ndiv) ||
        !conf_int(file, "BUSY_REFRESH", &g->busy_refresh))
        return 0;
    if (!g->hbm) return 1;
    if (!conf_int(file, "IDLE_NDIV", &g->idle_ndiv) || !conf_int(file, "COOL_REFRESH", &g->cool_refresh) ||
        !conf_int(file, "COOL_C", &g->cool_c) || !conf_int(file, "HOT_C", &g->hot_c)) {
        logf_("%s: HBM=1 but the HBM keys are incomplete - SM-only", c->serial);
        g->hbm = 0;
        return 1;
    }
    if (!conf_int(file, "IDLE_REFRESH", &g->idle_refresh)) g->idle_refresh = g->cool_refresh;
    /* The receipts behind HBM=1 are bound to this driver and VBIOS. */
    if (conf_get(file, "DRIVER", want, sizeof(want)) &&
        nvmlSystemGetDriverVersion(have, sizeof(have)) == NVML_SUCCESS && strcmp(want, have) != 0) {
        logf_("%s: gated on driver %s, running %s - SM-only until re-gated", c->serial, want, have);
        g->hbm = 0;
    }
    if (conf_get(file, "VBIOS", want, sizeof(want)) &&
        nvmlDeviceGetVbiosVersion(c->dev, have, sizeof(have)) == NVML_SUCCESS && strcmp(want, have) != 0) {
        logf_("%s: gated on VBIOS %s, running %s - SM-only until re-gated", c->serial, want, have);
        g->hbm = 0;
    }
    return 1;
}

static int is_170hx(nvmlDevice_t d)
{
    nvmlPciInfo_t pci;
    unsigned id;
    if (nvmlDeviceGetPciInfo(d, &pci) != NVML_SUCCESS) return 0;
    id = pci.pciDeviceId >> 16;
    return (pci.pciDeviceId & 0xffff) == 0x10de && (id == 0x20c2 || id == 0x2082);
}

static void discover(void)
{
    unsigned n = 0;
    nvmlDeviceGetCount_v2(&n);
    for (unsigned i = 0; i < n && ncards < MAX_CARDS; i++) {
        struct card *c = &cards[ncards];
        nvmlPciInfo_t pci;
        char file[4096];
        memset(c, 0, sizeof(*c));
        if (nvmlDeviceGetHandleByIndex_v2(i, &c->dev) != NVML_SUCCESS || !is_170hx(c->dev)) continue;
        if (nvmlDeviceGetSerial(c->dev, c->serial, sizeof(c->serial)) != NVML_SUCCESS) continue;
        nvmlDeviceGetPciInfo(c->dev, &pci);
        /* NVML's busId is 00000000:07:00.0; sysfs and the helpers want 0000:07:00.0 */
        snprintf(c->bdf, sizeof(c->bdf), "%s", strlen(pci.busId) > 12 ? pci.busId + strlen(pci.busId) - 12 : pci.busId);
        for (char *p = c->bdf; *p; p++) *p = (char)tolower((unsigned char)*p);
        snprintf(file, sizeof(file), "%s/%s.conf", idle_dir, c->serial);
        if (access(file, R_OK) != 0) { logf_("%s (%s): not enabled, left alone", c->serial, c->bdf); continue; }
        if (!load_card_cfg(c, file)) { logf_("%s: malformed %s, left alone", c->serial, file); continue; }
        if (c->cfg.hbm) {
            c->ndiv = read_ndiv(c);
            c->refresh = read_refresh(c);
            if (c->ndiv < 0 || c->refresh < 0)
                logf_("%s: cannot read HBM state yet (BAR0 access?) - HBM left alone, retried every %.0f s",
                      c->serial, CHECK_EVERY_S);
        }
        c->hbm_c = hbm_temp(c);
        c->xids0 = count_xids(c);
            logf_("%s (%s): managed, %s; busy NDIV %d clk %d, idle NDIV %d clk %d, REFRESH %d busy/%d idle <=%dC, %d >=%dC",
              c->serial, c->bdf, c->cfg.hbm ? "HBM+SM" : "SM-only", c->cfg.busy_ndiv, c->cfg.busy_clk,
              c->cfg.hbm ? c->cfg.idle_ndiv : c->cfg.busy_ndiv, c->cfg.idle_clk,
              c->cfg.cool_refresh, c->cfg.idle_refresh, c->cfg.cool_c, c->cfg.busy_refresh, c->cfg.hot_c);
        ncards++;
    }
}

static void on_signal(int sig) { (void)sig; stop = 1; }

int main(void)
{
    char daemon_conf[4096];
    double t, last_temp = 0, last_check = 0;
    nvmlReturn_t r;

    idle_dir  = env_or("IDLE_DIR", "/var/lib/170tune/idle");
    run_dir   = env_or("RUN_DIR", "/run/170tune-idle");
    hbm_mclk  = env_or("HBM_MCLK", "/usr/local/bin/hbm_mclk");
    fbpa_regs = env_or("FBPA_REGS", "/usr/local/bin/fbpa_regs");
    snprintf(daemon_conf, sizeof(daemon_conf), "%s/daemon.conf", idle_dir);
    conf_int(daemon_conf, "GROUP", &group);
    {
        char v[32];
        if (conf_get(daemon_conf, "IDLE_AFTER", v, sizeof(v))) idle_after = atof(v);
        if (conf_get(daemon_conf, "BUSY_DELTA_W", v, sizeof(v))) busy_delta_w = atof(v);
    }
    mkdir(run_dir, 0755);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    if ((r = nvmlInit_v2()) != NVML_SUCCESS) { logf_("nvmlInit: %s", nvmlErrorString(r)); return 1; }
    discover();
    if (!ncards) { logf_("no enabled 170HX found - nothing to do"); nvmlShutdown(); return 0; }
    logf_("idle after %.1fs, %s", idle_after, group ? "cards move together (GROUP=1)" : "cards move independently");

    t = now_s();
    for (int i = 0; i < ncards; i++) { cards[i].last_active = t; restore_busy(&cards[i]); }
    write_status();

    while (!stop) {
        int any_active = 0, all_quiet = 1;
        double oldest_quiet = 1e9;
        t = now_s();

        for (int i = 0; i < ncards; i++) {
            struct card *c = &cards[i];
            nvmlUtilization_t u = { 0, 0 };
            if (c->disarmed) continue;
            if (paused_by_file(c)) {
                if (!c->paused) { restore_busy(c); c->paused = 1; logf_("%s: paused", c->serial); write_status(); }
                continue;
            }
            if (c->paused) {        /* a 170tune command may have moved anything: re-read, re-apply */
                c->paused = 0;
                if (c->cfg.hbm) { c->ndiv = read_ndiv(c); c->refresh = read_refresh(c); }
                c->last_active = t;
                restore_busy(c);
                logf_("%s: resumed", c->serial);
            }
            nvmlDeviceGetUtilizationRates(c->dev, &u);
            if (c->idle && c->baseline_w <= 0 && t - c->idle_since >= SETTLE_S) c->baseline_w = power_w(c);
            if (idle_activity(u.gpu, u.memory, c->idle, c->idle ? power_w(c) : 0, c->baseline_w, busy_delta_w))
                c->last_active = t;
            if (t - c->last_active < 1e-9) any_active = 1;
            if (t - c->last_active < idle_after) all_quiet = 0;
            if (t - c->last_active < oldest_quiet) oldest_quiet = t - c->last_active;
        }

        for (int i = 0; i < ncards; i++) {
            struct card *c = &cards[i];
            if (c->disarmed || c->paused) continue;
            if (group)
                set_state(c, idle_next_state(c->idle, any_active, all_quiet ? idle_after : oldest_quiet, idle_after), t);
            else
                set_state(c, idle_next_state(c->idle, t - c->last_active < 1e-9, t - c->last_active, idle_after), t);
        }

        if (t - last_temp >= TEMP_EVERY_S) {
            last_temp = t;
            for (int i = 0; i < ncards; i++) {
                struct card *c = &cards[i];
                if (c->disarmed || c->paused) continue;
                c->hbm_c = hbm_temp(c);
                apply_hbm(c);
            }
        }

        if (t - last_check >= CHECK_EVERY_S) {
            last_check = t;
            for (int i = 0; i < ncards; i++) {
                struct card *c = &cards[i];
                if (c->disarmed || c->paused) continue;
                if (count_xids(c) > c->xids0) { disarm(c, "new Xid"); continue; }
                /* A driver reload, a boot-apply or a GPU reset can put things back under us. */
                if (c->cfg.hbm) {
                    c->ndiv = read_ndiv(c);
                    c->refresh = read_refresh(c);
                    apply_hbm(c);
                }
                lock_clocks(c, c->idle);
            }
            write_status();
        }
        usleep(POLL_MS * 1000);
    }

    logf_("stopping: every card back on its busy profile");
    for (int i = 0; i < ncards; i++) if (!cards[i].disarmed) restore_busy(&cards[i]);
    write_status();
    nvmlShutdown();
    return 0;
}
