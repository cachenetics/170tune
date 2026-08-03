/*
 * hbm_mclk - set the CMP 170HX (GA100) HBM memory clock from USERSPACE, live.
 *
 * The HBM clock is the FBPA PLL NDIV multiplier: mem_clock = NDIV * 27 MHz
 * (stock 64 = 1728 MHz). The cmpunlocker unlock opens the FBPA_PLL PLM
 * (0x009a3c7c -> 0xffffffff), so once the driver is up and GSP has finished its
 * own devinit, the COEFF register is host-writable over BAR0 and a userspace
 * write is "post-GSP" - the same moment the in-kernel cmpUnlockMclkPostGsp()
 * uses. This tool does the identical 6-step sequence the kernel does, plus two
 * guards the kernel version lacks (all-ones false-lock guard, and a COEFF
 * restore on lock timeout), so 170tune can ladder NDIV live with no driver
 * rebuild. The change is VOLATILE (a reboot restores stock); persistence is a
 * systemd service that re-applies the qualified value, not a driver bake.
 *
 * Build: gcc -O2 -o hbm_mclk hbm_mclk.c
 *
 *   sudo hbm_mclk get              current NDIV / MHz / lock / PLM
 *   sudo hbm_mclk set 70           set NDIV 70 (1890 MHz), verify PLL lock
 *   sudo hbm_mclk -g 1 set 70      second card
 *
 * Exit: 0 = locked at the requested NDIV; 1 = usage/target error;
 *       2 = PLM closed (unlock not applied); 3 = PLL did not lock (COEFF restored).
 *
 * WARNING: this changes the live HBM clock. Too high an NDIV that still "locks"
 * can return wrong bytes without crashing - 170tune's hot correctness gate, not
 * this tool, is what calls an NDIV safe. Volatile: a reboot restores stock.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <sys/mman.h>

#define BAR0_SIZE   0x1000000UL     /* 16 MB */
#define MAX_GPUS    32
#define PCI_DEVICES "/sys/bus/pci/devices"

/* FBPA PLL registers (from cmpunlocker cmpunlock.c, verified on GA100 170HX). */
#define REG_PLL_PLM       0x00903c7cU   /* unicast FBPA0 PLL priv-level mask   */
#define REG_PLL_CFG       0x00903c90U   /* unicast FBPA0 PLL cfg; bit 0x20=lock */
#define REG_PLL_COEFF     0x00903c98U   /* unicast FBPA0 PLL coeff (read)      */
#define REG_PLL_COEFF_MC  0x0098bc98U   /* MULTICAST coeff (write all FBPAs)   */
#define REG_PRI_FENCE     0x001211fcU   /* PRI fence                           */

/* Full clock-change sequence (set-full): the proper self-refresh + PHY resync
 * the bare COEFF write skips. The DDLL recalibration re-trains the data-path
 * delay lines at the NEW clock - the reason a bare write is stuck at the
 * PHY-eye trained for the stock clock, and baking (which runs this) reaches a
 * higher NDIV. Ported from cmpunlocker cmpUnlockPostBooterLoad. */
#define REG_FBIO_BCAST    0x009a0590U   /* MEMCLK_CHANGE_ALERT = bit 31        */
#define REG_HBM_SREF      0x009a031cU   /* HBM self-refresh enter(1)/exit(0)   */
#define REG_DDLL_CAL      0x009a11dcU   /* DDLL calibration trigger = bit 0x40 */
#define REG_DDLL_ST0      0x009a0674U
#define REG_DDLL_ST1      0x009a0678U
#define FBPA_BASE         0x900000U
#define FBPA_STRIDE       0x4000U
#define FBPA_CNT          12U
#define PLL_CFG_OFF       0x3c90U
#define PLL_COEFF_OFF     0x3c98U

#define NDIV_SHIFT   8
#define NDIV_MASK    0xFFU
#define CFG_LOCK     0x20U
#define PLM_WRITE_L0 0x10U   /* WRITE_PROTECTION_LEVEL0_ENABLE: host (level-0) may write when set.
                             * The unlock sets this; a stock-closed PLM (e.g. 0xFFFFFFCF) has it
                             * clear. Do NOT require the whole register == 0xffffffff - reserved bits
                             * (seen: FBPA_PLL settles to 0xFFFFFFDF, write-L1 bit stays clear) are
                             * irrelevant to a host write. */
#define IS_PRI_ERROR(v)  (((v) & 0xFFF00000U) == 0xBAD00000U)
#define IS_ALLONES(v)    ((v) == 0xFFFFFFFFU)

#define NDIV_MIN 30
#define NDIV_MAX 80
#define LOCK_POLL_ITERS 200000

static volatile uint32_t *g_bar0;
static uint32_t rd(uint32_t off) { return g_bar0[off / 4]; }
static void     wr(uint32_t off, uint32_t v) { g_bar0[off / 4] = v; }
static uint32_t ndiv_of(uint32_t coeff) { return (coeff >> NDIV_SHIFT) & NDIV_MASK; }

/* ---------------------------------------------------------------- GPU list */
struct gpu { char bdf[64]; unsigned dev; };
static struct gpu g_gpus[MAX_GPUS];
static int g_ngpus;

static unsigned sysfs_hex(const char *bdf, const char *file)
{
    char path[320], buf[32];
    FILE *f;
    unsigned v = 0;
    snprintf(path, sizeof(path), "%s/%s/%s", PCI_DEVICES, bdf, file);
    f = fopen(path, "r");
    if (!f) return 0;
    if (fgets(buf, sizeof(buf), f)) v = (unsigned)strtoul(buf, NULL, 0);
    fclose(f);
    return v;
}

static int is_target(unsigned vendor, unsigned dev)
{
    return vendor == 0x10de && (dev == 0x20c2 || dev == 0x2082);
}

static void scan_gpus(void)
{
    struct dirent *e;
    DIR *d = opendir(PCI_DEVICES);
    if (!d) return;
    while ((e = readdir(d)) && g_ngpus < MAX_GPUS) {
        unsigned vendor, dev;
        if (e->d_name[0] == '.') continue;
        vendor = sysfs_hex(e->d_name, "vendor");
        dev    = sysfs_hex(e->d_name, "device");
        if (!is_target(vendor, dev)) continue;
        if (strlen(e->d_name) >= sizeof(g_gpus[0].bdf)) continue;
        strcpy(g_gpus[g_ngpus].bdf, e->d_name);
        g_gpus[g_ngpus].dev = dev;
        g_ngpus++;
    }
    closedir(d);
    for (int i = 0; i < g_ngpus; i++)
        for (int j = i + 1; j < g_ngpus; j++)
            if (strcmp(g_gpus[j].bdf, g_gpus[i].bdf) < 0) {
                struct gpu t = g_gpus[i]; g_gpus[i] = g_gpus[j]; g_gpus[j] = t;
            }
}

/* ------------------------------------------------------------------ set/get */

static int cmd_get(void)
{
    uint32_t coeff = rd(REG_PLL_COEFF);
    uint32_t cfg   = rd(REG_PLL_CFG);
    uint32_t plm   = rd(REG_PLL_PLM);
    if (IS_PRI_ERROR(coeff)) {
        printf("NDIV ? (COEFF PRI error 0x%08x)  PLM 0x%08x\n", coeff, plm);
        return 3;
    }
    printf("NDIV %u  (%u MHz)  COEFF 0x%08x  lock %u  PLM 0x%08x%s\n",
           ndiv_of(coeff), ndiv_of(coeff) * 27, coeff, (cfg >> 5) & 1U, plm,
           (plm & PLM_WRITE_L0) ? " (host-write enabled)" : " (host-write BLOCKED - unlock not applied?)");
    return 0;
}

/* The live NDIV write: exactly cmpUnlockMclkPostGsp() plus the all-ones guard
 * and the COEFF restore on lock timeout. */
static int cmd_set(uint32_t newNdiv)
{
    uint32_t plm   = rd(REG_PLL_PLM);
    uint32_t coeff0 = rd(REG_PLL_COEFF);
    uint32_t newCoeff, cfg = 0;
    int locked = 0;
    long i;

    if (newNdiv < NDIV_MIN || newNdiv > NDIV_MAX) {
        fprintf(stderr, "NDIV %u out of range [%u..%u]\n", newNdiv, NDIV_MIN, NDIV_MAX);
        return 1;
    }
    /* Host (level-0) writes must be enabled, or the multicast write is silently
     * dropped and the clock never moves (looks like a no-op). Guard on the
     * write-level-0 bit, not the whole register (reserved bits vary). */
    if (!(plm & PLM_WRITE_L0)) {
        fprintf(stderr, "FBPA_PLL PLM 0x%08x: level-0 (host) write not enabled - unlock did not "
                        "open it. A host write would be dropped. Aborting.\n", plm);
        return 2;
    }
    if (coeff0 == 0 || IS_PRI_ERROR(coeff0) || IS_ALLONES(coeff0)) {
        /* Fall back to the 300W layout (MDIV=1, PDIV=1) if the stock read is bad. */
        newCoeff = (1U << 16) | (newNdiv << NDIV_SHIFT) | 1U;
        fprintf(stderr, "warning: stock COEFF read 0x%08x looks bad; using 300W layout\n", coeff0);
    } else {
        newCoeff = (coeff0 & ~(NDIV_MASK << NDIV_SHIFT)) | ((newNdiv & NDIV_MASK) << NDIV_SHIFT);
    }

    printf("PRE : NDIV %u (COEFF 0x%08x) -> NDIV %u (COEFF 0x%08x)\n",
           ndiv_of(coeff0), coeff0, newNdiv, newCoeff);

    wr(REG_PLL_COEFF_MC, newCoeff);     /* multicast to every FBPA */
    wr(REG_PRI_FENCE, 0x0U);            /* fence the write */
    for (i = 0; i < 500; i++) (void)rd(REG_PLL_CFG);   /* settle */

    for (i = 0; i < LOCK_POLL_ITERS; i++) {
        cfg = rd(REG_PLL_CFG);
        if (IS_ALLONES(cfg))            /* link error / hammer retrain: NOT a lock */
            continue;
        if (cfg & CFG_LOCK) { locked = 1; break; }
    }

    if (!locked) {
        /* Restore the original coefficient so we do not leave the HBM on an
         * unlocked PLL (garbage clock). The kernel version omits this. */
        wr(REG_PLL_COEFF_MC, coeff0);
        wr(REG_PRI_FENCE, 0x0U);
        fprintf(stderr, "FAIL: PLL did not lock at NDIV %u (CFG 0x%08x); COEFF restored to 0x%08x\n",
                newNdiv, cfg, coeff0);
        return 3;
    }

    {
        uint32_t coeff1 = rd(REG_PLL_COEFF);
        printf("POST: NDIV %u (COEFF 0x%08x) lock 1 iter %ld\n", ndiv_of(coeff1), coeff1, i);
        if (ndiv_of(coeff1) != newNdiv) {
            fprintf(stderr, "FAIL: COEFF readback NDIV %u != requested %u\n", ndiv_of(coeff1), newNdiv);
            return 3;
        }
    }
    return 0;
}

static void msleep(unsigned ms) { usleep(ms * 1000U); }

/* DDLL recalibration ALONE, at the live clock - recal the PHY data eye without
 * cycling the PLL (which re-locks conservative). This is the userspace path
 * higher: a bare `set N` runs the full clock but with the stock-trained eye
 * (1 error at 71); a `ddll` right after re-trains the eye at the live rate and
 * the errors clear WITHOUT losing bandwidth. GPU should be idle; volatile. */
static int cmd_ddll(void)
{
    uint32_t d = rd(REG_DDLL_CAL), poll;
    wr(REG_DDLL_CAL, d | 0x40U); msleep(10);
    for (poll = 0; poll < 100; poll++) { msleep(1); (void)rd(REG_DDLL_ST0); (void)rd(REG_DDLL_ST1); }
    wr(REG_DDLL_CAL, d & ~0x40U);
    printf("DDLL recal done; status 0x%08x 0x%08x\n", rd(REG_DDLL_ST0), rd(REG_DDLL_ST1));
    return 0;
}

/* The full clock-change protocol with PHY resync (self-refresh + PLL cycle +
 * DDLL recalibration). Riskier than the bare write - it puts DRAM into
 * self-refresh, so the GPU must be IDLE; volatile, a reboot recovers a hang. */
static int cmd_set_full(uint32_t newNdiv)
{
    uint32_t plm = rd(REG_PLL_PLM);
    uint32_t fbio0, i, poll, fbpaCount = 0, failCount = 0;

    if (newNdiv < NDIV_MIN || newNdiv > NDIV_MAX) {
        fprintf(stderr, "NDIV %u out of range [%u..%u]\n", newNdiv, NDIV_MIN, NDIV_MAX);
        return 1;
    }
    if (!(plm & PLM_WRITE_L0)) {
        fprintf(stderr, "FBPA_PLL PLM 0x%08x: level-0 write not enabled. Aborting.\n", plm);
        return 2;
    }
    printf("FULL clock change -> NDIV %u (%u MHz): alert + self-refresh + PLL cycle + DDLL recal\n",
           newNdiv, newNdiv * 27);

    fbio0 = rd(REG_FBIO_BCAST);                     /* 1. assert MEMCLK_CHANGE_ALERT */
    wr(REG_FBIO_BCAST, fbio0 | 0x80000000U);

    wr(REG_HBM_SREF, 0x1U); msleep(5);              /* 2. enter self-refresh */

    for (i = 0; i < FBPA_CNT; i++) {                /* 3. PLL cycle each active FBPA */
        uint32_t base = FBPA_BASE + i * FBPA_STRIDE;
        uint32_t cfgA = base + PLL_CFG_OFF, coA = base + PLL_COEFF_OFF;
        uint32_t oc = rd(cfgA), ocoeff = rd(coA), nc, lock = 0;
        if (oc == 0 || ocoeff == 0 || IS_PRI_ERROR(oc)) continue;
        fbpaCount++;
        wr(cfgA, oc & ~0x09U); msleep(2);
        nc = (ocoeff & ~0xFF00U) | ((newNdiv & 0xFFU) << 8);
        wr(coA, nc);
        wr(cfgA, (oc | 0x09U) & ~0x20U);
        for (poll = 0; poll < 200; poll++) { msleep(1); lock = rd(cfgA); if (lock & 0x20U) break; }
        if (!(lock & 0x20U)) { fprintf(stderr, "FBPA%u PLL lock timeout\n", i); failCount++; continue; }
        wr(cfgA, lock & ~0x1000U);
    }

    wr(REG_HBM_SREF, 0x0U); msleep(10);             /* 4. exit self-refresh */

    {                                                /* 5. DDLL recalibration (the PHY resync) */
        uint32_t d = rd(REG_DDLL_CAL);
        wr(REG_DDLL_CAL, d | 0x40U); msleep(10);
        for (poll = 0; poll < 100; poll++) { msleep(1); (void)rd(REG_DDLL_ST0); (void)rd(REG_DDLL_ST1); }
        wr(REG_DDLL_CAL, d & ~0x40U);
        printf("DDLL cal status 0x%08x 0x%08x\n", rd(REG_DDLL_ST0), rd(REG_DDLL_ST1));
    }

    wr(REG_FBIO_BCAST, rd(REG_FBIO_BCAST) & ~0x80000000U);  /* 6. clear alert */

    if (fbpaCount == 0) { fprintf(stderr, "no active FBPAs found\n"); return 3; }
    if (failCount > 0) { fprintf(stderr, "%u/%u FBPAs failed to lock\n", failCount, fbpaCount); return 3; }
    printf("POST: NDIV %u (COEFF 0x%08x) %u FBPAs (%u MHz)\n",
           ndiv_of(rd(REG_PLL_COEFF)), rd(REG_PLL_COEFF), fbpaCount, newNdiv * 27);
    return 0;
}

int main(int argc, char **argv)
{
    const char *bdf = getenv("GPU_BDF");
    int idx = 0, fd, a = 1;
    char path[320];

    while (a < argc && argv[a][0] == '-' && argv[a][1] && !argv[a][2]) {
        if (argv[a][1] == 'g' && a + 1 < argc)      { idx = atoi(argv[++a]); a++; }
        else if (argv[a][1] == 'b' && a + 1 < argc) { bdf = argv[++a]; a++; }
        else break;
    }
    if (a >= argc) {
        fprintf(stderr, "usage: %s [-g N | -b BDF] get | set <NDIV>\n", argv[0]);
        return 1;
    }

    scan_gpus();
    if (!bdf) {
        if (!g_ngpus) { fprintf(stderr, "no CMP 170HX found (10de:20c2 / 10de:2082)\n"); return 1; }
        if (idx < 0 || idx >= g_ngpus) { fprintf(stderr, "GPU index %d out of range, %d found\n", idx, g_ngpus); return 1; }
        bdf = g_gpus[idx].bdf;
    }

    snprintf(path, sizeof(path), "%s/%s/resource0", PCI_DEVICES, bdf);
    fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) { fprintf(stderr, "open %s: %s (run as root?)\n", path, strerror(errno)); return 1; }
    g_bar0 = mmap(NULL, BAR0_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (g_bar0 == MAP_FAILED) { fprintf(stderr, "mmap %s: %s\n", path, strerror(errno)); close(fd); return 1; }

    int rc;
    if (!strcmp(argv[a], "get") && argc == a + 1) {
        rc = cmd_get();
    } else if (!strcmp(argv[a], "set") && argc == a + 2) {
        rc = cmd_set((uint32_t)strtoul(argv[a + 1], NULL, 0));
    } else if (!strcmp(argv[a], "set-full") && argc == a + 2) {
        rc = cmd_set_full((uint32_t)strtoul(argv[a + 1], NULL, 0));
    } else if (!strcmp(argv[a], "ddll") && argc == a + 1) {
        rc = cmd_ddll();
    } else {
        fprintf(stderr, "usage: %s [-g N | -b BDF] get | set <NDIV> | ddll | set-full <NDIV>\n", argv[0]);
        rc = 1;
    }

    munmap((void *)g_bar0, BAR0_SIZE);
    close(fd);
    return rc;
}
