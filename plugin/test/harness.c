// Host test harness for the VitaPresence kernel plugin. run.sh builds it with AddressSanitizer and
// UndefinedBehaviorSanitizer and runs it.
//
// It compiles src/main.c unmodified against fake kernel APIs (fakesdk/), then checks every packet byte by
// byte the way a client parses it, plus the server loop and module start-up. It can only show that the
// plugin does the right thing when the console behaves like the fakes; that still needs a real Vita.
//
// Usage: harness [directory]   (with a directory, also saves sample packets there as *.bin)
#define _XOPEN_SOURCE 700 // nftw, mkdtemp and pread on glibc
#define _DARWIN_C_SOURCE  // and keeps mkdtemp declared on macOS

#include <fcntl.h>
#include <ftw.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <vitasdkkern.h>
#include <taihen.h>

// main.c aliases _start to module_start for the Vita's loader, which Mach-O can't express. Turning the
// attribute into `unused` leaves a harmless weak declaration. Every header main.c includes is already
// included above, so the macro reaches nothing else.
#define alias(target) unused
#include "../src/main.c"
#undef alias

#define CHECK(cond, ...) do { \
        g_checks++; \
        if (!(cond)) { g_failures++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } \
    } while (0)

static int g_checks, g_failures, g_violations;
static const char *g_dump_dir;

static void violation(const char *what) {
    printf("VIOLATION: %s\n", what);
    g_violations++;
}

// ------------------------------------------------------------------------------------------- fakes

// File system: "dev:path" is read from <root>/dev/path
static char g_root[1024];
static int g_opens, g_open_files;
static char g_open_log[8][64];

// SceAppMgr: its mutex and its app list, sized to end exactly at the last byte the plugin may read
#define FAKE_LIST_SIZE (APP_LIST_SPAN_END - APP_LIST_OFFSET)
static uint32_t g_mutex_uid = 0x4242;
static uint8_t *g_applist;
static int g_locked, g_lock_result;

// Adrenaline's shared struct in the PspEmu process
static SceUID g_adr_pid = -1;
static int g_adr_result;
static SceAdrenaline g_adr;

SceUID ksceIoOpen(const char *file, int flags, SceMode mode) {
    if (g_locked)
        violation("ksceIoOpen while holding SceAppMgr's mutex");
    if (flags != SCE_O_RDONLY)
        violation("file not opened read-only");
    if (g_opens < 8)
        snprintf(g_open_log[g_opens], sizeof(g_open_log[0]), "%s", file);
    g_opens++;

    const char *colon = strchr(file, ':');
    if (colon == NULL)
        return (SceUID)0x80010002;
    char path[2048];
    snprintf(path, sizeof(path), "%s/%.*s/%s", g_root, (int)(colon - file), file, colon + 1);
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return (SceUID)0x80010002; // ENOENT
    g_open_files++;
    return fd;
}

int ksceIoClose(SceUID fd) {
    g_open_files--;
    return close(fd);
}

int ksceIoPread(SceUID fd, void *data, SceSize size, SceOff offset) {
    if (g_locked)
        violation("ksceIoPread while holding SceAppMgr's mutex");
    ssize_t n = pread(fd, data, size, offset);
    return n < 0 ? (int)0x80010005 : (int)n;
}

int ksceKernelLockMutex(SceUID mutexid, int lockCount, unsigned int *timeout) {
    if (mutexid != (SceUID)g_mutex_uid || lockCount != 1 || timeout != NULL)
        violation("unexpected lock");
    if (g_lock_result < 0)
        return g_lock_result;
    g_locked++;
    return 0;
}

int ksceKernelUnlockMutex(SceUID mutexid, int unlockCount) {
    if (mutexid != (SceUID)g_mutex_uid || unlockCount != 1 || g_locked <= 0)
        violation("unexpected unlock");
    g_locked--;
    return 0;
}

int ksceKernelCopyFromUserProc(SceUID pid, void *dst, const void *src, SceSize len) {
    if (g_locked)
        violation("cross-process copy while holding SceAppMgr's mutex");
    if (src != (const void *)0x73CDE000 || len != sizeof(SceAdrenaline))
        violation("unexpected cross-process copy");
    if (g_adr_result < 0)
        return g_adr_result;
    if (pid != g_adr_pid)
        return (int)0x80020005;
    memcpy(dst, &g_adr, sizeof(g_adr));
    return 0;
}

// Test convention: pids from 0x400000 up run in PspEmu
int ksceSblACMgrIsPspEmu(SceUID pid) {
    return pid >= 0x400000;
}

// taiHEN, threads and sockets, recorded for the start-up and server tests
static int g_tai_result;
static char g_tai_module[32];
static uint8_t *g_segment;      // SceAppMgr's data segment (segment 1)
static size_t g_segment_size;
static size_t g_offsets[8];
static int g_noffsets;

static SceUID g_create_result;
static struct {
    char name[32];
    SceKernelThreadEntry entry;
    int priority, affinity;
    SceSize stack;
    SceUInt attr;
    int created, started, waited, deleted;
    SceUID started_uid, waited_uid, deleted_uid;
} g_thread;

static int g_sockets, g_binds, g_bind_failures, g_listens, g_delays, g_accepts_left, g_sends, g_ncloses;
static SceUInt g_delay_total;
static SceNetSockaddrIn g_bound;
static uint8_t g_sent[512];
static unsigned int g_sent_len;
static int g_closed[8];

int taiGetModuleInfoForKernel(SceUID pid, const char *module, tai_module_info_t *info) {
    if (pid != KERNEL_PID || info->size != sizeof(tai_module_info_t))
        violation("unexpected taiGetModuleInfoForKernel");
    snprintf(g_tai_module, sizeof(g_tai_module), "%s", module);
    if (g_tai_result < 0)
        return g_tai_result;
    info->modid = 0x51;
    return 0;
}

// Same rule as taiHEN: an offset past the end of the segment is an error
int module_get_offset(SceUID pid, SceUID modid, int segidx, size_t offset, uintptr_t *addr) {
    if (pid != KERNEL_PID || modid != 0x51 || segidx != 1)
        violation("unexpected module_get_offset");
    if (g_noffsets < 8)
        g_offsets[g_noffsets] = offset;
    g_noffsets++;
    if (offset > g_segment_size)
        return (int)0x90010002; // TAI_ERROR_INVALID_ARGS
    *addr = (uintptr_t)g_segment + offset;
    return 0;
}

SceUID ksceKernelCreateThread(const char *name, SceKernelThreadEntry entry, int initPriority,
                              SceSize stackSize, SceUInt attr, int cpuAffinityMask,
                              const SceKernelThreadOptParam *option) {
    g_thread.created++;
    snprintf(g_thread.name, sizeof(g_thread.name), "%s", name);
    g_thread.entry = entry;
    g_thread.priority = initPriority;
    g_thread.stack = stackSize;
    g_thread.attr = attr;
    g_thread.affinity = cpuAffinityMask;
    if (option != NULL)
        violation("unexpected thread options");
    return g_create_result;
}

int ksceKernelStartThread(SceUID thid, SceSize arglen, void *argp) {
    g_thread.started++;
    g_thread.started_uid = thid;
    return 0;
}

int ksceKernelWaitThreadEnd(SceUID thid, int *stat, SceUInt *timeout) {
    g_thread.waited++;
    g_thread.waited_uid = thid;
    return 0;
}

int ksceKernelDeleteThread(SceUID thid) {
    g_thread.deleted++;
    g_thread.deleted_uid = thid;
    return 0;
}

int ksceKernelDelayThread(SceUInt delay) {
    g_delays++;
    g_delay_total += delay;
    return 0;
}

int ksceNetSocket(const char *name, int domain, int type, int protocol) {
    if (domain != SCE_NET_AF_INET || type != SCE_NET_SOCK_STREAM || protocol != 0)
        violation("unexpected socket");
    g_sockets++;
    return 7;
}

int ksceNetBind(int s, const SceNetSockaddr *addr, unsigned int addrlen) {
    if (s != 7 || addrlen != sizeof(SceNetSockaddrIn))
        violation("unexpected bind");
    memcpy(&g_bound, addr, sizeof(g_bound));
    return ++g_binds <= g_bind_failures ? (int)0x80410170 : 0; // EADDRINUSE, then success
}

int ksceNetListen(int s, int backlog) {
    if (s != 7 || backlog <= 0)
        violation("unexpected listen");
    g_listens++;
    return 0;
}

static int g_accept_blocks;
static int g_accept_waiting;
static int g_listener_closed;
static pthread_mutex_t g_accept_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_accept_cv = PTHREAD_COND_INITIALIZER;

// Hands out g_accepts_left connections (fd 8), then stops the server thread.
// With g_accept_blocks, it waits until the listener is closed, the way ksceNetAccept blocks on hardware.
int ksceNetAccept(int s, SceNetSockaddr *addr, unsigned int *addrlen) {
    if (s != 7 || *addrlen != sizeof(SceNetSockaddrIn))
        violation("unexpected accept");
    if (g_accept_blocks) {
        pthread_mutex_lock(&g_accept_mu);
        g_accept_waiting = 1;
        while (!g_listener_closed)
            pthread_cond_wait(&g_accept_cv, &g_accept_mu);
        g_accept_waiting = 0;
        pthread_mutex_unlock(&g_accept_mu);
        g_thread_run = false;
        return (int)0x80410104;
    }
    if (g_accepts_left > 0) {
        g_accepts_left--;
        return 8;
    }
    g_thread_run = false;
    return (int)0x80410104;
}

int ksceNetSendto(int s, const void *msg, unsigned int len, int flags, const SceNetSockaddr *to, unsigned int tolen) {
    if (s != 8 || flags != 0 || to != NULL || tolen != 0 || len > sizeof(g_sent))
        violation("unexpected send");
    g_sends++;
    g_sent_len = len;
    memcpy(g_sent, msg, len < sizeof(g_sent) ? len : sizeof(g_sent));
    return (int)len;
}

int ksceNetClose(int s) {
    if (s == 7 && g_accept_blocks) {
        pthread_mutex_lock(&g_accept_mu);
        g_listener_closed = 1;
        pthread_cond_broadcast(&g_accept_cv);
        pthread_mutex_unlock(&g_accept_mu);
    }
    if (g_ncloses < 8)
        g_closed[g_ncloses] = s;
    g_ncloses++;
    return 0;
}

// ----------------------------------------------------------------------------------------- helpers

static int remove_entry(const char *path, const struct stat *st, int type, struct FTW *ftw) {
    return remove(path);
}

static void wipe_root(void) {
    nftw(g_root, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
    mkdir(g_root, 0700);
}

static void make_dirs(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(path, 0700);
            *p = '/';
        }
    }
}

static void put_file(const char *vita_path, const void *data, size_t len) {
    const char *colon = strchr(vita_path, ':');
    char path[2048];
    snprintf(path, sizeof(path), "%s/%.*s/%s", g_root, (int)(colon - vita_path), vita_path, colon + 1);
    make_dirs(path);
    FILE *f = fopen(path, "wb");
    if (f == NULL || fwrite(data, 1, len, f) != len || fclose(f) != 0) {
        perror(path);
        exit(2);
    }
}

static void put32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}

static void put16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

static uint32_t le32(const uint8_t *p) {
    return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

#define FMT_UTF8_SPECIAL 0x0004 // not NUL-terminated
#define FMT_UTF8         0x0204
#define FMT_INT32        0x0404

typedef struct {
    const char *key;
    uint16_t fmt;
    const char *str;  // value of a string parameter
    uint32_t num;     // value of an FMT_INT32 parameter
    uint32_t max;     // paramMaxLen; 0 = value length rounded up to 4
} param_t;

static uint32_t param_len(const param_t *p) {
    if (p->fmt == FMT_INT32)
        return 4;
    return (uint32_t)strlen(p->str) + (p->fmt == FMT_UTF8_SPECIAL ? 0 : 1);
}

static uint32_t param_max(const param_t *p) {
    uint32_t len = param_len(p);
    uint32_t max = p->max ? p->max : (len + 3) & ~3u;
    if (max < len)
        abort();
    return max;
}

// Writes a param.sfo laid out like the official tools do: header, index, key table padded to 4 bytes,
// data table. Returns its size.
static size_t build_sfo(uint8_t *out, size_t cap, const param_t *params, int n) {
    uint32_t keys_size = 0, data_size = 0;
    for (int i = 0; i < n; i++) {
        keys_size += (uint32_t)strlen(params[i].key) + 1;
        data_size += param_max(&params[i]);
    }
    keys_size = (keys_size + 3) & ~3u;
    uint32_t key_table = 20 + 16 * (uint32_t)n, data_table = key_table + keys_size;
    size_t total = data_table + data_size;
    if (total > cap)
        abort();

    memset(out, 0, total);
    put32(out, 0x46535000);
    put32(out + 4, 0x0101);
    put32(out + 8, key_table);
    put32(out + 12, data_table);
    put32(out + 16, (uint32_t)n);
    uint32_t key_off = 0, data_off = 0;
    for (int i = 0; i < n; i++) {
        const param_t *p = &params[i];
        uint8_t *entry = out + 20 + 16 * i;
        put16(entry, (uint16_t)key_off);
        put16(entry + 2, p->fmt);
        put32(entry + 4, param_len(p));
        put32(entry + 8, param_max(p));
        put32(entry + 12, data_off);
        memcpy(out + key_table + key_off, p->key, strlen(p->key) + 1);
        if (p->fmt == FMT_INT32)
            put32(out + data_table + data_off, p->num);
        else
            memcpy(out + data_table + data_off, p->str, param_len(p));
        key_off += (uint32_t)strlen(p->key) + 1;
        data_off += param_max(p);
    }
    return total;
}

// A retail game's param.sfo: sorted keys, STITLE before TITLE before TITLE_ID, official field sizes
static size_t retail_sfo(uint8_t *out, size_t cap, const char *content_id, const char *title_id) {
    const param_t params[] = {
        { "APP_VER",           FMT_UTF8,  "01.00",          0,          8 },
        { "ATTRIBUTE",         FMT_INT32, NULL,             0x8000,     4 },
        { "ATTRIBUTE2",        FMT_INT32, NULL,             0,          4 },
        { "ATTRIBUTE_MINOR",   FMT_INT32, NULL,             0x10,       4 },
        { "CATEGORY",          FMT_UTF8,  "gd",             0,          4 },
        { "CONTENT_ID",        FMT_UTF8,  content_id,       0,          0x30 },
        { "GC_RO_SIZE",        FMT_INT32, NULL,             0,          4 },
        { "GC_RW_SIZE",        FMT_INT32, NULL,             0,          4 },
        { "PARENTAL_LEVEL",    FMT_INT32, NULL,             5,          4 },
        { "PSP2_DISP_VER",     FMT_UTF8,  "00.000",         0,          8 },
        { "PSP2_SYSTEM_VER",   FMT_INT32, NULL,             0x01650000, 4 },
        { "REGION_DENY",       FMT_INT32, NULL,             0,          4 },
        { "SAVEDATA_MAX_SIZE", FMT_INT32, NULL,             0x10000,    4 },
        { "STITLE",            FMT_UTF8,  "Project DIVA f", 0,          0x34 },
        { "TITLE",             FMT_UTF8,  "Hatsune Miku: Project DIVA f", 0, 0x80 },
        { "TITLE_ID",          FMT_UTF8,  title_id,         0,          0x0C },
        { "VERSION",           FMT_UTF8,  "01.00",          0,          8 },
    };
    return build_sfo(out, cap, params, (int)(sizeof(params) / sizeof(params[0])));
}

// A homebrew param.sfo with only the given CONTENT_ID/TITLE parameters (NULL leaves one out)
static size_t homebrew_sfo(uint8_t *out, size_t cap, const char *content_id, uint16_t content_id_fmt,
                           const char *title, const char *title_id) {
    param_t params[3];
    int n = 0;
    if (content_id != NULL)
        params[n++] = (param_t){ "CONTENT_ID", content_id_fmt, content_id, 0x1234, 0 };
    if (title != NULL)
        params[n++] = (param_t){ "TITLE", FMT_UTF8, title, 0, 0 };
    params[n++] = (param_t){ "TITLE_ID", FMT_UTF8, title_id, 0, 0 };
    return build_sfo(out, cap, params, n);
}

static void clear_list(void) {
    memset(g_applist, 0, FAKE_LIST_SIZE);
}

static void set_entry(int slot, SceUID pid, uint32_t state, const char *titleid, const char *bubbleid, const char *title) {
    uint8_t *e = g_applist + (size_t)slot * APP_LIST_ENTRY_SIZE;
    memcpy(e + 0x578, &pid, 4);
    memcpy(e + 0xAA0, &state, 4);
    strncpy((char *)e + 0x900, titleid, 0x20);
    strncpy((char *)e + 0x558, bubbleid, 0x20);
    strncpy((char *)e + 0x62C, title, 0x200);
}

// Every scenario starts with an empty file system, an empty app list and a cold cache
static void reset_state(void) {
    wipe_root();
    clear_list();
    memset(&g_sfo_cache, 0, sizeof(g_sfo_cache));
    g_sfo_cache.pid = -1;
    g_opens = 0;
    g_lock_result = 0;
    g_adr_pid = -1;
    g_adr_result = 0;
    memset(&g_adr, 0, sizeof(g_adr));
}

// The Mac client's rule: 36 characters, '-' at 6 and 19, '_' at 16, ASCII letters or digits elsewhere
static bool client_accepts_content_id(const char *s) {
    if (strlen(s) != 36)
        return false;
    for (int i = 0; i < 36; i++) {
        char c = s[i];
        bool ok = i == 6 || i == 19 ? c == '-' : i == 16 ? c == '_' :
            (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        if (!ok)
            return false;
    }
    return true;
}

// One packet as a client sees it: strings cut at the first NUL of their field
typedef struct {
    uint8_t raw[sizeof(vitapresence_data_t)];
    uint32_t magic;
    int32_t index;
    char titleid[TITLEID_LEN + 1];
    char title[TITLE_LEN + 1];
    char contentid[CONTENTID_LEN + 1];
} wire_t;

static void check_field(const uint8_t *field, size_t size, const char *name) {
    size_t len = 0;
    while (len < size && field[len] != 0)
        len++;
    CHECK(len < size, "%s is not NUL-terminated inside its field", name);
    for (size_t i = len; i < size; i++) {
        if (field[i] != 0) {
            CHECK(false, "%s byte %zu after the NUL is 0x%02X", name, i, field[i]);
            break;
        }
    }
}

static wire_t decode(const uint8_t *b) {
    wire_t w;
    memset(&w, 0, sizeof(w));
    memcpy(w.raw, b, sizeof(w.raw));
    w.magic = le32(b);
    w.index = (int32_t)le32(b + 4);
    memcpy(w.titleid, b + 8, TITLEID_LEN);
    memcpy(w.title, b + 18, TITLE_LEN);
    memcpy(w.contentid, b + 146, CONTENTID_LEN);

    CHECK(b[0] == 0xFE && b[1] == 0xCA && b[2] == 0xFE && b[3] == 0xCA, "magic bytes");
    CHECK(w.index >= 0 && w.index <= APP_LIST_ENTRIES, "index %d", w.index);
    check_field(b + 8, TITLEID_LEN, "titleid");
    check_field(b + 18, TITLE_LEN, "title");
    check_field(b + 146, CONTENTID_LEN, "contentid");
    CHECK(b[183] == 0, "tail padding byte is 0x%02X", b[183]);
    CHECK(w.contentid[0] == 0 || client_accepts_content_id(w.contentid), "malformed content ID '%s'", w.contentid);
    if (w.index == 0) {
        for (size_t i = 4; i < sizeof(w.raw); i++) {
            if (b[i] != 0) {
                CHECK(false, "LiveArea packet byte %zu is 0x%02X", i, b[i]);
                break;
            }
        }
    }
    return w;
}

// Builds a packet over garbage, to prove every byte is rewritten
static wire_t packet(void) {
    static vitapresence_data_t data;
    memset(&data, 0xA5, sizeof(data));
    fill_packet(&data);
    CHECK(g_locked == 0, "SceAppMgr's mutex left locked");
    CHECK(g_open_files == 0, "%d file(s) left open", g_open_files);
    return decode((const uint8_t *)&data);
}

static void dump(const char *name, const wire_t *w) {
    if (g_dump_dir == NULL)
        return;
    char path[2048];
    snprintf(path, sizeof(path), "%s/%s", g_dump_dir, name);
    FILE *f = fopen(path, "wb");
    if (f == NULL || fwrite(w->raw, 1, sizeof(w->raw), f) != sizeof(w->raw) || fclose(f) != 0) {
        perror(path);
        exit(2);
    }
}

#define DIVA_US "UP0177-PCSE00326_00-PJDF393MAJITENSI"
#define DIVA_EU "EP0177-PCSB00419_00-PJDF393MAJITENSI"
#define DIVA   "Hatsune Miku: Project DIVA f"

// ------------------------------------------------------------------------------------------- tests

static void test_helpers(void) {
    char s[16];
    snprintf(s, sizeof(s), "ab\xE3\x81");
    utf8_trim_incomplete(s, sizeof(s));
    CHECK(!strcmp(s, "ab") && s[2] == 0 && s[3] == 0, "cut 3-byte sequence dropped");
    const char *kept[] = { "abc", "a\xC3\xA9", "\xE3\x81\x82", "\xF0\x9F\x98\x80", "ab\x80", "" };
    for (size_t i = 0; i < sizeof(kept) / sizeof(kept[0]); i++) {
        snprintf(s, sizeof(s), "%s", kept[i]);
        utf8_trim_incomplete(s, sizeof(s));
        CHECK(!strcmp(s, kept[i]), "'%s' must be kept", kept[i]);
    }
    const char *dropped[] = { "\xC3", "x\xF0\x9F\x98", "x\xF0\x9F", "x\xE3" };
    for (size_t i = 0; i < sizeof(dropped) / sizeof(dropped[0]); i++) {
        snprintf(s, sizeof(s), "%s", dropped[i]);
        utf8_trim_incomplete(s, sizeof(s));
        CHECK(strlen(s) == (dropped[i][0] == 'x' ? 1u : 0u), "incomplete sequence %zu kept", i);
    }

    char unterminated[4] = { 'W', 'X', 'Y', 'Z' }, dst[8];
    memset(dst, 0x55, sizeof(dst));
    copy_field(dst, sizeof(dst), unterminated, sizeof(unterminated));
    CHECK(!memcmp(dst, "WXYZ\0\0\0\0", 8), "copy_field must stop at src_max and zero-fill");
    copy_field(dst, 3, "abcdef", 6);
    CHECK(!strcmp(dst, "ab"), "copy_field must leave room for the NUL");

    CHECK(is_path_safe_id("PCSE00326") && is_path_safe_id("VITASHELL") && is_path_safe_id("A_1"), "safe ids");
    const char *unsafe[] = { "", "../x", "a/b", "a:b", "PCSE 0032", "ABCDEFGHIJ" };
    for (size_t i = 0; i < sizeof(unsafe) / sizeof(unsafe[0]); i++) {
        char id[16] = { 0 };
        snprintf(id, sizeof(id), "%s", unsafe[i]);
        CHECK(!is_path_safe_id(id), "'%s' must not be path-safe", unsafe[i]);
    }
}

static void test_livearea(void) {
    reset_state();
    wire_t w = packet();
    CHECK(w.index == 0 && w.titleid[0] == 0 && w.title[0] == 0 && w.contentid[0] == 0, "LiveArea packet");
    CHECK(g_opens == 0, "LiveArea must not touch files");
    dump("livearea.bin", &w);
}

static void test_digital_game(void) {
    uint8_t sfo[1024];
    reset_state();
    put_file("ux0:app/PCSE00326/sce_sys/param.sfo", sfo, retail_sfo(sfo, sizeof(sfo), DIVA_US, "PCSE00326"));
    set_entry(0, 0x100010, APP_RUNNING, "NPXS10079", "NPXS10079", "Daily Checker BG");
    set_entry(1, 0x100011, APP_RUNNING, "NPXS10063", "NPXS10063", "MsgMW");
    set_entry(2, 0x100012, APP_SUSPENDED, "PCSE00120", "PCSE00120", "Suspended game");
    set_entry(3, 0x100013, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    wire_t w = packet();
    CHECK(w.index == 4, "background apps and suspended games are skipped (index %d)", w.index);
    CHECK(!strcmp(w.titleid, "PCSE00326") && !strcmp(w.title, DIVA), "title ID and title from SceAppMgr");
    CHECK(!strcmp(w.contentid, DIVA_US), "content ID '%s'", w.contentid);
    CHECK(g_opens == 1 && !strcmp(g_open_log[0], "ux0:app/PCSE00326/sce_sys/param.sfo"), "one open (%d)", g_opens);
    dump("vita-game.bin", &w);

    w = packet();
    CHECK(g_opens == 1 && !strcmp(w.contentid, DIVA_US), "the next poll is served from the cache (%d opens)", g_opens);

    set_entry(3, 0x100099, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    w = packet();
    CHECK(g_opens == 2 && !strcmp(w.contentid, DIVA_US), "a relaunch (new pid) reads the file again");

    set_entry(3, 0x100099, APP_RUNNING, "PCSE00120", "PCSE00120", "Persona 4 Golden");
    w = packet();
    CHECK(g_opens == 5 && w.contentid[0] == 0, "another title ID gets its own lookup (%d opens)", g_opens);
    CHECK(!strcmp(w.titleid, "PCSE00120") && !strcmp(w.title, "Persona 4 Golden"), "other title");
}

static void test_sfo_locations(void) {
    uint8_t us[1024], eu[1024], junk[512];
    size_t us_len = retail_sfo(us, sizeof(us), DIVA_US, "PCSE00326");
    size_t eu_len = retail_sfo(eu, sizeof(eu), DIVA_EU, "PCSE00326");
    memset(junk, 0x5A, sizeof(junk));

    // Game card: no ux0 copy
    reset_state();
    put_file("gro0:app/PCSE00326/sce_sys/param.sfo", us, us_len);
    set_entry(0, 0x100020, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    wire_t w = packet();
    CHECK(!strcmp(w.contentid, DIVA_US), "game card content ID '%s'", w.contentid);
    CHECK(g_opens == 2 && !strcmp(g_open_log[0], "ux0:app/PCSE00326/sce_sys/param.sfo") &&
          !strcmp(g_open_log[1], "gro0:app/PCSE00326/sce_sys/param.sfo"), "ux0 first, then gro0");
    dump("game-card.bin", &w);

    // A ux0 copy that isn't a plain SFO is skipped
    reset_state();
    put_file("ux0:app/PCSE00326/sce_sys/param.sfo", junk, sizeof(junk));
    put_file("gro0:app/PCSE00326/sce_sys/param.sfo", us, us_len);
    set_entry(0, 0x100021, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    w = packet();
    CHECK(!strcmp(w.contentid, DIVA_US) && g_opens == 2, "falls through past a non-SFO file");

    // The system's metadata copy comes last
    reset_state();
    put_file("ur0:appmeta/PCSE00326/param.sfo", eu, eu_len);
    set_entry(0, 0x100022, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    w = packet();
    CHECK(!strcmp(w.contentid, DIVA_EU) && g_opens == 3 && !strcmp(g_open_log[2], "ur0:appmeta/PCSE00326/param.sfo"),
          "ur0:appmeta fallback");

    // ux0 wins over gro0 when both exist
    reset_state();
    put_file("ux0:app/PCSE00326/sce_sys/param.sfo", us, us_len);
    put_file("gro0:app/PCSE00326/sce_sys/param.sfo", eu, eu_len);
    set_entry(0, 0x100023, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    w = packet();
    CHECK(!strcmp(w.contentid, DIVA_US) && g_opens == 1, "ux0 first");

    // The first SFO that parses ends the search, even without a CONTENT_ID
    reset_state();
    size_t n = homebrew_sfo(us, sizeof(us), NULL, 0, "No ID", "PCSE00326");
    put_file("ux0:app/PCSE00326/sce_sys/param.sfo", us, n);
    put_file("gro0:app/PCSE00326/sce_sys/param.sfo", eu, eu_len);
    set_entry(0, 0x100024, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    w = packet();
    CHECK(w.contentid[0] == 0 && g_opens == 1, "stops at the first valid SFO");

    // Nothing anywhere: three probes, and the failure is cached
    reset_state();
    set_entry(0, 0x100025, APP_RUNNING, "PCSE00999", "PCSE00999", "Missing");
    w = packet();
    CHECK(w.contentid[0] == 0 && g_opens == 3 && !strcmp(w.title, "Missing"), "no SFO (%d opens)", g_opens);
    w = packet();
    CHECK(g_opens == 3, "a failed lookup is cached too");
}

static void test_system_and_unsafe_ids(void) {
    reset_state();
    set_entry(0, 0x100040, APP_RUNNING, "NPXS10015", "NPXS10015", "Settings");
    wire_t w = packet();
    CHECK(!strcmp(w.titleid, "NPXS10015") && !strcmp(w.title, "Settings") && w.contentid[0] == 0, "system app");
    CHECK(g_opens == 0, "system apps cause no file I/O");
    dump("system-app.bin", &w);

    reset_state();
    set_entry(0, 0x100041, APP_RUNNING, "../../x", "../../x", "Evil");
    w = packet();
    CHECK(g_opens == 0 && !strcmp(w.titleid, "../../x"), "an unsafe title ID never reaches a path");

    reset_state();
    set_entry(0, 0x100042, APP_RUNNING, "", "", "No ID");
    w = packet();
    CHECK(g_opens == 0 && w.index == 1 && !strcmp(w.title, "No ID"), "an empty title ID causes no I/O");
}

static void test_content_id_parsing(void) {
    uint8_t sfo[4096];
    reset_state();
    put_file("ux0:app/VITASHELL/sce_sys/param.sfo", sfo,
             homebrew_sfo(sfo, sizeof(sfo), "HB0001-VITASHELL_00-0000000000000000", FMT_UTF8, "VitaShell", "VITASHELL"));
    set_entry(0, 0x100070, APP_RUNNING, "VITASHELL", "VITASHELL", "VitaShell");
    wire_t w = packet();
    CHECK(!strcmp(w.contentid, "HB0001-VITASHELL_00-0000000000000000"), "homebrew ID passes the shape check");
    dump("homebrew.bin", &w);

    const struct {
        const char *value;
        uint16_t fmt;
        const char *expected;
    } cases[] = {
        { DIVA_US,                                       FMT_UTF8_SPECIAL, DIVA_US }, // no NUL in the file
        { "up0177-pcse00326_00-pjdf393majitensi",        FMT_UTF8,         "up0177-pcse00326_00-pjdf393majitensi" },
        { DIVA_US "XX",                                  FMT_UTF8,         "" },      // too long
        { "UP0177-PCSE00326_00-PJDF393MAJITENS",         FMT_UTF8,         "" },      // too short
        { "UP0177 PCSE00326_00-PJDF393MAJITENSI",        FMT_UTF8,         "" },
        { "UP0177_PCSE00326-00-PJDF393MAJITENSI",        FMT_UTF8,         "" },
        { "UP0177-PCSE00326_00-PJDF393MAJ%TENSI",        FMT_UTF8,         "" },
        { "UP0177-PCSE00326_00-PJDF393MAJ_TENSI",        FMT_UTF8,         "" },
        { "UP0177-PCSE00326_00-PJDF393MAJ\xC3\xA9TENS",  FMT_UTF8,         "" },
        { "",                                            FMT_UTF8,         "" },
        { DIVA_US,                                       FMT_INT32,        "" },      // a number
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        reset_state();
        put_file("ux0:app/VITASHELL/sce_sys/param.sfo", sfo,
                 homebrew_sfo(sfo, sizeof(sfo), cases[i].value, cases[i].fmt, "VitaShell", "VITASHELL"));
        set_entry(0, 0x100071, APP_RUNNING, "VITASHELL", "VITASHELL", "VitaShell");
        w = packet();
        CHECK(!strcmp(w.contentid, cases[i].expected), "case %zu: content ID '%s'", i, w.contentid);
    }

    // A well-formed ID under a format other than a string is ignored
    const uint16_t other_formats[] = { FMT_INT32, 0x0000, 0x0104 };
    for (size_t i = 0; i < sizeof(other_formats) / sizeof(other_formats[0]); i++) {
        reset_state();
        size_t n = homebrew_sfo(sfo, sizeof(sfo), DIVA_US, FMT_UTF8, "VitaShell", "VITASHELL");
        put16(sfo + 20 + 2, other_formats[i]);
        put_file("ux0:app/VITASHELL/sce_sys/param.sfo", sfo, n);
        set_entry(0, 0x100072, APP_RUNNING, "VITASHELL", "VITASHELL", "VitaShell");
        w = packet();
        CHECK(w.contentid[0] == 0, "format 0x%04X accepted", other_formats[i]);
    }

    // Keys must match exactly
    const param_t near_misses[] = {
        { "CONTENT_I",   FMT_UTF8, DIVA_US,     0, 0 },
        { "CONTENT_ID2", FMT_UTF8, DIVA_US,     0, 0 },
        { "TITLE_ID",    FMT_UTF8, "VITASHELL", 0, 0 },
    };
    reset_state();
    put_file("ux0:app/VITASHELL/sce_sys/param.sfo", sfo, build_sfo(sfo, sizeof(sfo), near_misses, 3));
    set_entry(0, 0x100073, APP_RUNNING, "VITASHELL", "VITASHELL", "VitaShell");
    w = packet();
    CHECK(w.contentid[0] == 0, "CONTENT_I / CONTENT_ID2 must not match CONTENT_ID");

    // A key offset past this file's key table must not find what an earlier file left in the buffer:
    // first parse a file with CONTENT_ID at key offset 210, then one whose only key points there
    static param_t padded[31];
    static char names[30][8];
    for (int i = 0; i < 30; i++) {
        snprintf(names[i], sizeof(names[i]), "AAAA%02d", i);
        padded[i] = (param_t){ names[i], FMT_INT32, NULL, 0, 4 };
    }
    padded[30] = (param_t){ "CONTENT_ID", FMT_UTF8, DIVA_EU, 0, 0 };
    reset_state();
    put_file("ux0:app/VITASHELL/sce_sys/param.sfo", sfo, build_sfo(sfo, sizeof(sfo), padded, 31));
    set_entry(0, 0x100074, APP_RUNNING, "VITASHELL", "VITASHELL", "VitaShell");
    w = packet();
    CHECK(!strcmp(w.contentid, DIVA_EU) && !memcmp(g_sfo_keys + 210, "CONTENT_ID", 11), "key at offset 210");
    const param_t lone = { "X", FMT_UTF8, DIVA_US, 0, 0 };
    size_t n = build_sfo(sfo, sizeof(sfo), &lone, 1);
    put16(sfo + 20, 210);
    put_file("ux0:app/PCSE00326/sce_sys/param.sfo", sfo, n);
    set_entry(0, 0x100075, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    w = packet();
    CHECK(w.contentid[0] == 0, "stale key table bytes matched ('%s')", w.contentid);

    // At most 128 parameters, the size of the index buffer
    static param_t many[129];
    static char many_names[129][8];
    many[0] = (param_t){ "CONTENT_ID", FMT_UTF8, DIVA_US, 0, 0 };
    for (int i = 1; i < 129; i++) {
        snprintf(many_names[i], sizeof(many_names[i]), "Z%03d", i);
        many[i] = (param_t){ many_names[i], FMT_INT32, NULL, 0, 4 };
    }
    for (int count = 128; count <= 129; count++) {
        reset_state();
        put_file("ux0:app/VITASHELL/sce_sys/param.sfo", sfo, build_sfo(sfo, sizeof(sfo), many, count));
        set_entry(0, 0x100076, APP_RUNNING, "VITASHELL", "VITASHELL", "VitaShell");
        w = packet();
        CHECK(!strcmp(w.contentid, count == 128 ? DIVA_US : ""), "%d parameters: content ID '%s'", count, w.contentid);
    }

    // A value that runs past the end of the file is dropped
    reset_state();
    n = homebrew_sfo(sfo, sizeof(sfo), DIVA_US, FMT_UTF8, "VitaShell", "VITASHELL");
    put_file("ux0:app/VITASHELL/sce_sys/param.sfo", sfo, le32(sfo + 12) + 20);
    set_entry(0, 0x100077, APP_RUNNING, "VITASHELL", "VITASHELL", "VitaShell");
    w = packet();
    CHECK(w.contentid[0] == 0 && n > le32(sfo + 12) + 20, "truncated value");
}

static void test_pspemu_bubble(void) {
    uint8_t sfo[4096];
    char long_title[200] = "";
    for (int i = 0; i < 50; i++)
        strcat(long_title, "\xE3\x81\x82"); // U+3042, 150 bytes in all

    reset_state();
    put_file("ux0:app/PSPB00001/sce_sys/param.sfo", sfo,
             homebrew_sfo(sfo, sizeof(sfo), "EP9000-NPEG00001_00-0000000000000001", FMT_UTF8, long_title, "PSPB00001"));
    set_entry(0, 0x400001, APP_RUNNING, "NPXS10028", "PSPB00001", "PSP");
    wire_t w = packet();
    size_t len = strlen(w.title);
    CHECK(!strcmp(w.titleid, "PSPB00001"), "bubble ID as the title ID ('%s')", w.titleid);
    CHECK(len == 126 && !memcmp(w.title, long_title, 126), "title from the SFO, cut before a split character (%zu)", len);
    CHECK(!strcmp(w.contentid, "EP9000-NPEG00001_00-0000000000000001"), "bubble content ID");
    dump("psp-bubble.bin", &w);

    // No TITLE: TITLE_ID must not stand in for it; the bubble ID does
    reset_state();
    put_file("ux0:app/PSPB00001/sce_sys/param.sfo", sfo, homebrew_sfo(sfo, sizeof(sfo), NULL, 0, NULL, "PSPB00001"));
    set_entry(0, 0x400001, APP_RUNNING, "NPXS10028", "PSPB00001", "PSP");
    w = packet();
    CHECK(!strcmp(w.title, "PSPB00001") && w.contentid[0] == 0, "falls back to the bubble ID ('%s')", w.title);

    // An official PSP bubble with only the system's metadata copy
    reset_state();
    put_file("ur0:appmeta/NPUZ00001/param.sfo", sfo,
             homebrew_sfo(sfo, sizeof(sfo), "UP9000-NPUZ00001_00-LOCOROCOPSPGAMES", FMT_UTF8, "LocoRoco", "NPUZ00001"));
    set_entry(0, 0x400002, APP_RUNNING, "NPXS10028", "NPUZ00001", "PSP");
    w = packet();
    CHECK(!strcmp(w.title, "LocoRoco") && !strcmp(w.contentid, "UP9000-NPUZ00001_00-LOCOROCOPSPGAMES") && g_opens == 3,
          "PSP bubble via ur0:appmeta");

    // No SFO at all
    reset_state();
    set_entry(0, 0x400003, APP_RUNNING, "NPXS10028", "PSPB00002", "PSP");
    w = packet();
    CHECK(!strcmp(w.titleid, "PSPB00002") && !strcmp(w.title, "PSPB00002") && w.contentid[0] == 0, "bubble without an SFO");
}

static void test_adrenaline(void) {
    reset_state();
    set_entry(0, 0x400010, APP_RUNNING, "NPXS10028", "PSPEMUCFW", "Adrenaline");
    g_adr_pid = 0x400010;
    snprintf(g_adr.titleid, sizeof(g_adr.titleid), "ULUS10041");
    snprintf(g_adr.title, sizeof(g_adr.title), "Grand Theft Auto: Liberty City Stories");
    wire_t w = packet();
    CHECK(!strcmp(w.titleid, "ULUS10041") && !strcmp(w.title, "Grand Theft Auto: Liberty City Stories"), "PSP game");
    CHECK(w.contentid[0] == 0 && g_opens == 0, "Adrenaline: no file I/O, no content ID");
    dump("adrenaline-psp.bin", &w);

    snprintf(g_adr.titleid, sizeof(g_adr.titleid), "SLUS00594");
    snprintf(g_adr.title, sizeof(g_adr.title), "Metal Gear Solid");
    g_adr.pops_mode = 1;
    w = packet();
    CHECK(!strcmp(w.titleid, "SLUS00594") && !strcmp(w.title, "Metal Gear Solid"), "PS1 game");
    dump("adrenaline-ps1.bin", &w);

    memset(&g_adr, 0, sizeof(g_adr));
    snprintf(g_adr.title, sizeof(g_adr.title), "leftover");
    w = packet();
    CHECK(!strcmp(w.titleid, "XMB") && !strcmp(w.title, "Adrenaline XMB Menu"), "XMB (no title ID)");
    dump("adrenaline-xmb.bin", &w);
    snprintf(g_adr.titleid, sizeof(g_adr.titleid), "XMB");
    w = packet();
    CHECK(!strcmp(w.titleid, "XMB") && !strcmp(w.title, "Adrenaline XMB Menu"), "XMB");

    memset(&g_adr, 0x41, sizeof(g_adr));
    w = packet();
    CHECK(strlen(w.titleid) == 9 && strlen(w.title) == 127, "unterminated Adrenaline strings stay bounded");

    memset(&g_adr, 0, sizeof(g_adr));
    snprintf(g_adr.titleid, sizeof(g_adr.titleid), "NPJH50465");
    memset(g_adr.title, 'a', 126);
    memcpy(g_adr.title + 126, "\xE3\x81\x82", 2); // a 3-byte character cut by the 127-byte limit
    w = packet();
    CHECK(strlen(w.title) == 126, "Adrenaline title cut before a split character (%zu)", strlen(w.title));

    g_adr_result = (int)0x80020005;
    w = packet();
    CHECK(!strcmp(w.titleid, "PSPEMUCFW") && !strcmp(w.title, "Adrenaline") && w.index == 1, "failed copy reports Adrenaline");
}

static void test_appmgr_edge_cases(void) {
    reset_state();
    set_entry(0, 0x100080, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    g_lock_result = (int)0x80028004;
    wire_t w = packet();
    CHECK(w.index == 0 && g_opens == 0, "a failed lock reads as the LiveArea, as in 1.0");

    // Strings in SceAppMgr that run on up to the next field stay bounded (an unbounded copy would overrun
    // the plugin's buffers, which ASan reports); the next packet carries none of them
    reset_state();
    SceUID pid = 0x100090;
    uint32_t state = APP_RUNNING;
    memset(g_applist + 0x558, 'Y', 0x578 - 0x558); // bubble ID, up to the pid
    memset(g_applist + 0x62C, 'T', 0x900 - 0x62C); // title, up to the title ID
    memset(g_applist + 0x900, 'Z', 0xAA0 - 0x900); // title ID, up to the state
    memcpy(g_applist + 0x578, &pid, 4);
    memcpy(g_applist + 0xAA0, &state, 4);
    w = packet();
    CHECK(strlen(w.titleid) == 9 && strlen(w.title) == 127, "SceAppMgr strings bounded");
    clear_list();
    w = packet();
    CHECK(w.index == 0, "LiveArea after a long title (stale bytes checked by decode)");

    // A title cut at 127 bytes loses a split character
    reset_state();
    char title[200];
    memset(title, 'b', 126);
    snprintf(title + 126, sizeof(title) - 126, "\xE2\x84\xA2 tail");
    set_entry(0, 0x100091, APP_RUNNING, "NPXS10015", "NPXS10015", title);
    w = packet();
    CHECK(strlen(w.title) == 126, "SceAppMgr title cut before a split character (%zu)", strlen(w.title));

    // The last slot is read without going past SceAppMgr's data (ASan checks the end of the fake list)
    reset_state();
    set_entry(APP_LIST_ENTRIES - 1, 0x100092, APP_RUNNING, "NPXS10015", "NPXS10015", "Settings");
    w = packet();
    CHECK(w.index == APP_LIST_ENTRIES && !strcmp(w.title, "Settings"), "last slot (index %d)", w.index);
}

// Clients that predate 1.1 read only bytes 0..145; PR #13 clients also read contentid at 146
static void test_old_clients(void) {
    uint8_t sfo[1024];
    reset_state();
    put_file("ux0:app/PCSE00326/sce_sys/param.sfo", sfo, retail_sfo(sfo, sizeof(sfo), DIVA_US, "PCSE00326"));
    set_entry(0, 0x1000A0, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    wire_t w = packet();
    char titleid[11] = { 0 }, title[129] = { 0 }, contentid[38] = { 0 };
    memcpy(titleid, w.raw + 8, 10);
    memcpy(title, w.raw + 18, 128);
    memcpy(contentid, w.raw + 146, 37);
    CHECK(le32(w.raw) == 0xCAFECAFE && le32(w.raw + 4) == 1 && !strcmp(titleid, "PCSE00326") && !strcmp(title, DIVA),
          "1.0 client view");
    CHECK(!strcmp(contentid, DIVA_US), "PR #13 client view");
    CHECK(sizeof(vitapresence_data_t) == 184, "184 bytes on the wire");
}

static void test_fuzzed_sfo(void) {
    uint8_t retail[1024], m[1024 + 64];
    size_t retail_len = retail_sfo(retail, sizeof(retail), DIVA_US, "PCSE00326");
    reset_state();
    set_entry(0, 0x1000B0, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    srand(12345);
    int kept = 0;
    for (int iter = 0; iter < 20000; iter++) {
        size_t len = retail_len;
        memcpy(m, retail, retail_len);
        int mutations = 1 + rand() % 8;
        for (int j = 0; j < mutations; j++) {
            switch (rand() % 4) {
            case 0: m[rand() % (int)len] = (uint8_t)rand(); break;                 // anywhere
            case 1: m[rand() % 20] = (uint8_t)rand(); break;                       // header
            case 2: m[20 + rand() % (16 * 17)] = (uint8_t)rand(); break;           // index
            default: len = 1 + (size_t)(rand() % (int)retail_len); break;          // truncation
            }
        }
        put_file("ux0:app/PCSE00326/sce_sys/param.sfo", m, len);
        g_sfo_cache.pid = -1;
        wire_t w = packet();
        if (w.contentid[0] != 0)
            kept++;
    }
    printf("fuzz: 20000 mutated SFOs, %d still gave a well-formed content ID\n", kept);
}

static void test_server_loop(void) {
    uint8_t sfo[1024];
    reset_state();
    put_file("ux0:app/PCSE00326/sce_sys/param.sfo", sfo, retail_sfo(sfo, sizeof(sfo), DIVA_US, "PCSE00326"));
    set_entry(0, 0x1000C0, APP_RUNNING, "PCSE00326", "PCSE00326", DIVA);
    g_thread_run = true;
    g_bind_failures = 1;
    g_accepts_left = 1;
    memset(&g_bound, 0xEE, sizeof(g_bound));

    int ret = vitapresence_thread(0, NULL);
    CHECK(ret == 0 && !g_thread_run, "thread ends when stopped");
    CHECK(g_sockets == 1 && g_binds == 2 && g_listens == 1, "bind retried (%d binds)", g_binds);
    CHECK(g_delays == 2 && g_delay_total == 4 * 1000 * 1000, "2 s before each bind attempt");
    const uint8_t *a = (const uint8_t *)&g_bound;
    static const uint8_t expected[16] = { 16, SCE_NET_AF_INET, 0xCA, 0xFE };
    CHECK(!memcmp(a, expected, sizeof(expected)), "bound to 0.0.0.0:51966 with sin_len set and the rest zero");
    CHECK(g_sends == 1 && g_sent_len == 184, "one 184-byte send (%d sends, %u bytes)", g_sends, g_sent_len);
    wire_t w = decode(g_sent);
    CHECK(w.index == 1 && !strcmp(w.titleid, "PCSE00326") && !strcmp(w.contentid, DIVA_US), "sent packet");
    CHECK(g_ncloses == 2 && g_closed[0] == 8 && g_closed[1] == 7, "client closed, then the listener");
}

static void test_module_start_stop(void) {
    g_segment_size = APP_LIST_SPAN_END;
    g_segment = calloc(1, g_segment_size);
    uint32_t *saved_mutex = SceAppMgr_mutex_uid, *saved_list = SceAppMgr_app_list;
    const struct {
        int tai_result;
        size_t segment_size;
        SceUID create_result;
        int expected;
        int offsets;
        int created;
    } cases[] = {
        { (int)0x90010007, APP_LIST_SPAN_END,     0x40001,         SCE_KERNEL_START_NO_RESIDENT, 0, 0 }, // no SceAppMgr
        { 0,               0x4A3,                 0x40001,         SCE_KERNEL_START_NO_RESIDENT, 1, 0 },
        { 0,               APP_LIST_OFFSET - 1,   0x40001,         SCE_KERNEL_START_NO_RESIDENT, 2, 0 },
        { 0,               APP_LIST_SPAN_END - 1, 0x40001,         SCE_KERNEL_START_NO_RESIDENT, 3, 0 }, // list cut short
        { 0,               APP_LIST_SPAN_END,     (int)0x80020001, SCE_KERNEL_START_NO_RESIDENT, 3, 1 }, // no thread
        { 0,               APP_LIST_SPAN_END,     0x40001,         SCE_KERNEL_START_SUCCESS,     3, 1 },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        memset(&g_thread, 0, sizeof(g_thread));
        g_noffsets = 0;
        g_tai_result = cases[i].tai_result;
        g_segment_size = cases[i].segment_size;
        g_create_result = cases[i].create_result;
        g_thread_uid = -1;
        g_thread_run = true;

        int ret = module_start(0, NULL);
        bool started = cases[i].expected == SCE_KERNEL_START_SUCCESS;
        CHECK(ret == cases[i].expected, "case %zu: module_start returned %d", i, ret);
        CHECK(!strcmp(g_tai_module, "SceAppMgr"), "case %zu: looks up SceAppMgr", i);
        CHECK(g_noffsets == cases[i].offsets, "case %zu: %d offsets requested", i, g_noffsets);
        CHECK(g_thread.created == cases[i].created, "case %zu: thread created %d times", i, g_thread.created);
        CHECK(g_thread.started == started, "case %zu: thread started %d times", i, g_thread.started);
    }
    CHECK(g_offsets[0] == 0x4A4 && g_offsets[1] == 0x500 && g_offsets[2] == 0x2BCD4, "offsets 0x4A4, 0x500, 0x2BCD4");
    CHECK(SceAppMgr_mutex_uid == (uint32_t *)(g_segment + 0x4A4) && SceAppMgr_app_list == (uint32_t *)(g_segment + 0x500),
          "SceAppMgr pointers");
    CHECK(!strcmp(g_thread.name, "vitapresence_thread") && g_thread.entry == vitapresence_thread, "thread entry");
    CHECK(g_thread.priority == 0x3C && g_thread.stack == 0x4000 && g_thread.attr == 0 && g_thread.affinity == 0x10000,
          "thread priority 0x3C, 16 KiB stack");
    CHECK(g_thread.started_uid == 0x40001, "started the created thread");

    int ret = module_stop(0, NULL);
    CHECK(ret == SCE_KERNEL_STOP_SUCCESS && !g_thread_run, "module_stop stops the thread");
    CHECK(g_thread.waited == 1 && g_thread.waited_uid == 0x40001 && g_thread.deleted == 1 && g_thread.deleted_uid == 0x40001,
          "module_stop waits for the thread, then deletes it");

    g_thread_uid = -1;
    memset(&g_thread, 0, sizeof(g_thread));
    module_stop(0, NULL);
    CHECK(g_thread.waited == 0 && g_thread.deleted == 0, "module_stop without a thread touches none");

    SceAppMgr_mutex_uid = saved_mutex;
    SceAppMgr_app_list = saved_list;
    free(g_segment);
}

static void *run_server_thread(void *unused) {
    (void)unused;
    vitapresence_thread(0, NULL);
    return NULL;
}

static void test_stop_wakes_blocked_accept(void) {
    pthread_t thread;
    g_accept_blocks = 1;
    g_accept_waiting = 0;
    g_listener_closed = 0;
    g_bind_failures = 0;
    g_thread_run = true;
    g_thread_uid = 0x40001;
    g_server_sockfd = -1;
    CHECK(pthread_create(&thread, NULL, run_server_thread, NULL) == 0, "server thread starts");
    for (int i = 0; i < 2000 && !g_accept_waiting; i++)
        usleep(1000);
    CHECK(g_accept_waiting, "accept blocks until the listener is closed");
    CHECK(module_stop(0, NULL) == SCE_KERNEL_STOP_SUCCESS, "module_stop");
    CHECK(pthread_join(thread, NULL) == 0, "server thread ends");
    CHECK(!g_thread_run && !g_accept_waiting, "closing the listener woke accept");
    g_accept_blocks = 0;
}

int main(int argc, char **argv) {
    if (argc > 1)
        g_dump_dir = argv[1];

    const char *tmp = getenv("TMPDIR");
    snprintf(g_root, sizeof(g_root), "%s/vitapresence-fs.XXXXXX", tmp != NULL && tmp[0] != '\0' ? tmp : "/tmp");
    if (mkdtemp(g_root) == NULL) {
        perror(g_root);
        return 2;
    }
    g_applist = calloc(1, FAKE_LIST_SIZE);
    SceAppMgr_app_list = (uint32_t *)g_applist;
    SceAppMgr_mutex_uid = &g_mutex_uid;

    test_helpers();
    test_livearea();
    test_digital_game();
    test_sfo_locations();
    test_system_and_unsafe_ids();
    test_content_id_parsing();
    test_pspemu_bubble();
    test_adrenaline();
    test_appmgr_edge_cases();
    test_old_clients();
    test_fuzzed_sfo();
    test_server_loop();
    test_module_start_stop();
    test_stop_wakes_blocked_accept();

    nftw(g_root, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
    free(g_applist);
    printf("%d checks, %d failures, %d violations\n", g_checks, g_failures, g_violations);
    return g_failures || g_violations ? 1 : 0;
}
