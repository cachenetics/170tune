/*
 * fbpa_regs - read/write CMP 170HX (GA100) FBPA memory-timing registers.
 *
 * Maps GPU BAR0 and pokes the FBPA broadcast aperture (0x009Axxxx), which fans
 * a write out to every FBPA on that GPU. These registers are PLM-gated on a
 * stock card; cmpunlocker opens the FBPA_MEM gate (0x009a0168) during the
 * unlock, so writes only stick on a patched driver.
 *
 * CONFIG0..CONFIG4 hold the live primary timings (USE_TIMING_REGS=0).
 * TIMINGn_GEN are read-only: the effective timings the controller generated.
 * A CONFIG write that does not move the matching _GEN field did not take.
 *
 * Build: gcc -O2 -o fbpa_regs fbpa_regs.c
 *
 *   sudo fbpa_regs list                 GPUs this tool can drive
 *   sudo fbpa_regs dump                 timings of GPU 0, in cycles
 *   sudo fbpa_regs -g 1 dump            ... of GPU 1
 *   sudo fbpa_regs get RAS              one field, machine-readable
 *   sudo fbpa_regs set RAS 45           change one field
 *   sudo fbpa_regs save before.txt      snapshot every timing register
 *   sudo fbpa_regs load before.txt      write a snapshot back
 *   sudo fbpa_regs read  0x009a0290     raw register
 *   sudo fbpa_regs write 0x009a0290 0x18569143
 *
 * WARNING: this changes live DRAM timing. Too-tight values corrupt data
 * silently or wedge the memory controller - and writing the old value back
 * does not recover that, only a reboot does. Nothing here is persistent.
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

#define CONFIG0     0x009A0290
#define CONFIG1     0x009A0294
#define CONFIG2     0x009A0298
#define CONFIG3     0x009A029C
#define CONFIG4     0x009A02A0
#define CONFIG10    0x009A02F4
#define TIMING0_GEN 0x009A02B0
#define TIMING1_GEN 0x009A02B4
#define TIMING2_GEN 0x009A02B8

static volatile uint32_t *g_bar0;

static uint32_t rd(uint32_t off) { return g_bar0[off / 4]; }
static void     wr(uint32_t off, uint32_t v) { g_bar0[off / 4] = v; }

static uint32_t width_max(int w) { return (w >= 32) ? 0xFFFFFFFFU : ((1U << w) - 1U); }
static uint32_t bits(uint32_t v, int hi, int lo) { return (v >> lo) & width_max(hi - lo + 1); }

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

/* CMP 170HX: 0x20C2 is the 8GB card, 0x2082 the 10GB one. */
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

    /* Stable order regardless of readdir. */
    for (int i = 0; i < g_ngpus; i++)
        for (int j = i + 1; j < g_ngpus; j++)
            if (strcmp(g_gpus[j].bdf, g_gpus[i].bdf) < 0) {
                struct gpu t = g_gpus[i]; g_gpus[i] = g_gpus[j]; g_gpus[j] = t;
            }
}

/* ------------------------------------------------------------------ fields */

struct field {
    const char *name;
    uint32_t    reg;
    const char *regname;
    int         lo, width;
    int         msb_lo, msb_width;   /* extension in CONFIG10, msb_width 0 = none */
    uint32_t    gen;                 /* read-only mirror, 0 = none */
    int         gen_lo, gen_width;
};

static const struct field fields[] = {
    { "RC",      CONFIG0, "CONFIG0",  0, 8,  0, 0, TIMING0_GEN,  0, 9 },
    { "RFC",     CONFIG0, "CONFIG0",  8, 9,  0, 2, TIMING0_GEN, 12, 11 },
    { "RAS",     CONFIG0, "CONFIG0", 17, 7,  0, 0, TIMING0_GEN, 24, 8 },
    { "RP",      CONFIG0, "CONFIG0", 24, 7,  0, 0, 0,            0, 0 },
    { "CL",      CONFIG1, "CONFIG1",  0, 7,  0, 0, 0,            0, 0 },
    { "WL",      CONFIG1, "CONFIG1",  7, 7,  0, 0, 0,            0, 0 },
    { "RD_RCD",  CONFIG1, "CONFIG1", 14, 6,  8, 1, TIMING2_GEN,  0, 8 },
    { "WR_RCD",  CONFIG1, "CONFIG1", 20, 6, 11, 1, TIMING2_GEN,  8, 8 },
    { "WR",      CONFIG2, "CONFIG2", 16, 7,  0, 0, 0,            0, 0 },
    { "W2R_BUS", CONFIG2, "CONFIG2", 24, 4,  0, 0, 0,            0, 0 },
    { "R2W_BUS", CONFIG2, "CONFIG2", 28, 4,  0, 0, 0,            0, 0 },
    { "FAW",     CONFIG3, "CONFIG3",  9, 8,  0, 0, 0,            0, 0 },
    { "CCDL",    CONFIG3, "CONFIG3", 24, 4,  0, 0, 0,            0, 0 },
    { "CCDS",    CONFIG3, "CONFIG3", 28, 4,  0, 0, 0,            0, 0 },
    { "RRD",     CONFIG4, "CONFIG4", 15, 6,  0, 0, TIMING2_GEN, 16, 7 },
    { "REFRESH",    CONFIG4, "CONFIG4", 3, 12, 0, 0, 0, 0, 0 },  /* tREFI, encoded (no _GEN mirror) */
    { "REFRESH_LO", CONFIG4, "CONFIG4", 0,  3, 0, 0, 0, 0, 0 },
};
#define NFIELDS ((int)(sizeof(fields) / sizeof(fields[0])))

/* Every register worth snapshotting. */
static const uint32_t snapshot_regs[] = {
    CONFIG0, CONFIG1, CONFIG2, CONFIG3, CONFIG4,
    0x009A02A4, 0x009A02A8, 0x009A02AC, 0x009A02CC, 0x009A02E8, CONFIG10,
};
#define NSNAP ((int)(sizeof(snapshot_regs) / sizeof(snapshot_regs[0])))

static const struct field *find_field(const char *name)
{
    for (int i = 0; i < NFIELDS; i++)
        if (!strcasecmp(fields[i].name, name)) return &fields[i];
    return NULL;
}

/* Field value including its CONFIG10 high-bit extension. */
static uint32_t field_get(const struct field *f)
{
    uint32_t v = bits(rd(f->reg), f->lo + f->width - 1, f->lo);
    if (f->msb_width)
        v |= bits(rd(CONFIG10), f->msb_lo + f->msb_width - 1, f->msb_lo) << f->width;
    return v;
}

static uint32_t field_max(const struct field *f)
{
    return width_max(f->width + f->msb_width);
}

static uint32_t field_gen(const struct field *f)
{
    if (!f->gen) return 0;
    return bits(rd(f->gen), f->gen_lo + f->gen_width - 1, f->gen_lo);
}

static int field_set(const struct field *f, uint32_t val)
{
    uint32_t reg, mask, before = field_get(f), gen_before = field_gen(f);

    if (val > field_max(f)) {
        fprintf(stderr, "%s: max is %u\n", f->name, field_max(f));
        return 1;
    }
    if (val == 0) {
        fprintf(stderr, "%s: refusing to set 0 - that is a broken register, not a tight timing\n",
                f->name);
        return 1;
    }

    mask = width_max(f->width) << f->lo;
    reg  = (rd(f->reg) & ~mask) | ((val & width_max(f->width)) << f->lo);
    wr(f->reg, reg);

    if (f->msb_width) {
        uint32_t mmask = width_max(f->msb_width) << f->msb_lo;
        uint32_t c10 = (rd(CONFIG10) & ~mmask) |
                       (((val >> f->width) & width_max(f->msb_width)) << f->msb_lo);
        wr(CONFIG10, c10);
    }

    printf("%s.%s: %u -> %u", f->regname, f->name, before, val);
    if (field_get(f) != val) {
        printf("   << READBACK MISMATCH (%u) - write did not stick\n", field_get(f));
        return 2;
    }
    if (f->gen) {
        uint32_t g = field_gen(f);
        printf("   _GEN %u -> %u %s\n", gen_before, g,
               g == val ? "(controller picked it up)" : "<< _GEN DID NOT FOLLOW");
        return g == val ? 0 : 3;
    }
    printf("   (no _GEN mirror - readback only)\n");
    return 0;
}

/* ---------------------------------------------------------------- commands */

static void cmd_dump(void)
{
    uint32_t c0 = rd(CONFIG0);

    printf("CONFIG0 0x%08X  CONFIG1 0x%08X  CONFIG2 0x%08X\n",
           c0, rd(CONFIG1), rd(CONFIG2));
    printf("CONFIG3 0x%08X  CONFIG4 0x%08X  CONFIG10 0x%08X\n",
           rd(CONFIG3), rd(CONFIG4), rd(CONFIG10));
    printf("T0_GEN  0x%08X  T1_GEN  0x%08X  T2_GEN   0x%08X\n\n",
           rd(TIMING0_GEN), rd(TIMING1_GEN), rd(TIMING2_GEN));

    if (bits(c0, 31, 31))
        printf("!! USE_TIMING_REGS=1 - the TIMING regs are live and CONFIG is ignored\n\n");

    printf("%-8s %6s  %-8s %s\n", "FIELD", "CYCLES", "REG", "EFFECTIVE");
    for (int i = 0; i < NFIELDS; i++) {
        printf("%-8s %6u  %-8s ", fields[i].name, field_get(&fields[i]), fields[i].regname);
        if (fields[i].gen) printf("%u\n", field_gen(&fields[i]));
        else               printf("-\n");
    }

    {
        uint32_t g1 = rd(TIMING1_GEN);
        printf("\ntR2W %u  tW2R %u  tR2P %u  tW2P %u   [TIMING1_GEN]\n",
               bits(g1, 7, 0), bits(g1, 14, 8), bits(g1, 20, 16), bits(g1, 30, 24));
    }
}

static int cmd_save(const char *path)
{
    FILE *f = strcmp(path, "-") ? fopen(path, "w") : stdout;

    if (!f) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }
    fprintf(f, "# fbpa_regs snapshot - restore with: fbpa_regs load <file>\n");
    for (int i = 0; i < NSNAP; i++)
        fprintf(f, "0x%08X 0x%08X\n", snapshot_regs[i], rd(snapshot_regs[i]));
    if (f != stdout) {
        fclose(f);
        fprintf(stderr, "saved %d registers to %s\n", NSNAP, path);
    }
    return 0;
}

static int cmd_load(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[128];
    int n = 0;

    if (!f) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }
    while (fgets(line, sizeof(line), f)) {
        uint32_t addr, val;
        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "%x %x", &addr, &val) != 2) continue;
        if (addr >= BAR0_SIZE) {
            fprintf(stderr, "skipping out-of-range 0x%08X\n", addr);
            continue;
        }
        wr(addr, val);
        if (rd(addr) != val)
            fprintf(stderr, "0x%08X: wrote 0x%08X, reads 0x%08X\n", addr, val, rd(addr));
        n++;
    }
    fclose(f);
    fprintf(stderr, "restored %d registers from %s\n", n, path);
    return 0;
}

static void usage(const char *p)
{
    fprintf(stderr,
        "Usage: %s [-g N | -b BDF] <command>\n\n"
        "  list                  GPUs this tool can drive\n"
        "  dump                  all timings, in cycles\n"
        "  get   <FIELD>         one field, bare number\n"
        "  set   <FIELD> <cyc>   change one field\n"
        "  save  <file>          snapshot every timing register ('-' for stdout)\n"
        "  load  <file>          write a snapshot back\n"
        "  read  <addr>          raw register\n"
        "  write <addr> <value>  raw register\n\n"
        "  -g N     GPU index from 'list' (default 0)\n"
        "  -b BDF   explicit PCI address, e.g. 0000:03:00.0\n"
        "  GPU_BDF  same as -b\n\n"
        "Fields: ", p);
    for (int i = 0; i < NFIELDS; i++)
        fprintf(stderr, "%s%s", fields[i].name, i + 1 < NFIELDS ? " " : "\n");
}

int main(int argc, char **argv)
{
    const char *bdf = getenv("GPU_BDF");
    int idx = 0, fd, rc = 0, a = 1;
    char path[320];

    while (a < argc && argv[a][0] == '-' && argv[a][1] && !argv[a][2]) {
        if (argv[a][1] == 'g' && a + 1 < argc)      { idx = atoi(argv[++a]); a++; }
        else if (argv[a][1] == 'b' && a + 1 < argc) { bdf = argv[++a]; a++; }
        else break;
    }

    if (a >= argc) { usage(argv[0]); return 1; }

    scan_gpus();

    if (!strcmp(argv[a], "list")) {
        if (!g_ngpus) { printf("no CMP 170HX found\n"); return 1; }
        for (int i = 0; i < g_ngpus; i++)
            printf("%d  %s  10de:%04x  %s\n", i, g_gpus[i].bdf, g_gpus[i].dev,
                   g_gpus[i].dev == 0x20c2 ? "8GB" : "10GB");
        return 0;
    }

    if (!bdf) {
        if (!g_ngpus) {
            fprintf(stderr, "no CMP 170HX found (10de:20c2 / 10de:2082)\n");
            return 1;
        }
        if (idx < 0 || idx >= g_ngpus) {
            fprintf(stderr, "GPU index %d out of range, %d found\n", idx, g_ngpus);
            return 1;
        }
        bdf = g_gpus[idx].bdf;
    }

    snprintf(path, sizeof(path), "%s/%s/resource0", PCI_DEVICES, bdf);
    fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s (run as root?)\n", path, strerror(errno));
        return 1;
    }

    g_bar0 = mmap(NULL, BAR0_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (g_bar0 == MAP_FAILED) {
        fprintf(stderr, "mmap %s: %s\n", path, strerror(errno));
        close(fd);
        return 1;
    }

    if (!strcmp(argv[a], "dump") && argc == a + 1) {
        cmd_dump();
    } else if (!strcmp(argv[a], "get") && argc == a + 2) {
        const struct field *f = find_field(argv[a + 1]);
        if (!f) { fprintf(stderr, "unknown field '%s'\n", argv[a + 1]); rc = 1; }
        else printf("%u\n", field_get(f));
    } else if (!strcmp(argv[a], "set") && argc == a + 3) {
        const struct field *f = find_field(argv[a + 1]);
        if (!f) { fprintf(stderr, "unknown field '%s'\n", argv[a + 1]); rc = 1; }
        else rc = field_set(f, (uint32_t)strtoul(argv[a + 2], NULL, 0));
    } else if (!strcmp(argv[a], "save") && argc == a + 2) {
        rc = cmd_save(argv[a + 1]);
    } else if (!strcmp(argv[a], "load") && argc == a + 2) {
        rc = cmd_load(argv[a + 1]);
    } else if (!strcmp(argv[a], "read") && argc == a + 2) {
        uint32_t ad = (uint32_t)strtoul(argv[a + 1], NULL, 0);
        printf("0x%08X = 0x%08X\n", ad, rd(ad));
    } else if (!strcmp(argv[a], "write") && argc == a + 3) {
        uint32_t ad = (uint32_t)strtoul(argv[a + 1], NULL, 0);
        uint32_t v  = (uint32_t)strtoul(argv[a + 2], NULL, 0);
        uint32_t b  = rd(ad);
        wr(ad, v);
        printf("0x%08X: 0x%08X -> 0x%08X%s\n", ad, b, rd(ad),
               rd(ad) == v ? "" : "  << READBACK MISMATCH");
        rc = (rd(ad) == v) ? 0 : 2;
    } else {
        usage(argv[0]);
        rc = 1;
    }

    munmap((void *)g_bar0, BAR0_SIZE);
    close(fd);
    return rc;
}
