#include <vitasdkkern.h>
#include <taihen.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "main.h"

int module_get_offset(SceUID pid, SceUID modid, int segidx, size_t offset, uintptr_t *addr);
int ksceSblACMgrIsPspEmu(SceUID pid);

static SceUID g_thread_uid = -1;
static volatile bool g_thread_run = true;
static volatile SceUID g_server_sockfd = -1;

static uint32_t *SceAppMgr_mutex_uid;
static uint32_t *SceAppMgr_app_list;

// Everything below is used by the server thread only. Large buffers are static to keep its stack small.

// Foreground app as copied out of SceAppMgr's list while holding its mutex
typedef struct {
    SceUID pid;
    bool is_pspemu;
    char titleid[TITLEID_LEN];
    char bubbleid[TITLEID_LEN];
    char title[TITLE_LEN];
} fg_app_t;

static fg_app_t g_fg;
static SceAdrenaline g_adrenaline;

// param.sfo lookup result, cached for one (pid, id) pair, failures included
typedef struct {
    SceUID pid;
    char id[TITLEID_LEN];
    bool has_title;
    char title[TITLE_LEN];
    char contentid[CONTENTID_LEN];
} sfo_info_t;

static sfo_info_t g_sfo_cache = { .pid = -1 };

#define SFO_MAGIC            0x46535000 // "\0PSF"
#define SFO_FMT_UTF8_SPECIAL 0x0004
#define SFO_FMT_UTF8         0x0204
#define SFO_MAX_ENTRIES      128
#define SFO_MAX_KEY_TABLE    0x800
#define SFO_CONTENT_ID_MAX   0x30

static sfo_entry_t g_sfo_index[SFO_MAX_ENTRIES];
static char g_sfo_keys[SFO_MAX_KEY_TABLE];
static char g_sfo_title[TITLE_LEN];
static char g_sfo_contentid[SFO_CONTENT_ID_MAX + 1];
static char g_sfo_path[64];

// Where a title's param.sfo can be, in lookup order
static const struct {
    const char *prefix;
    const char *suffix;
} k_sfo_locations[] = {
    { "ux0:app/",     "/sce_sys/param.sfo" }, // digital (and dumped card) games, homebrew, PspEmu bubbles
    { "gro0:app/",    "/sce_sys/param.sfo" }, // inserted game card
    { "ur0:appmeta/", "/param.sfo" },         // the system's metadata copy
};

// noinline here and below: at -O3, GCC otherwise unrolls these loops at every call site (.text ~5 -> ~18 KiB)
static __attribute__((noinline)) size_t bounded_strlen(const char *s, size_t max) {
    size_t n = 0;
    while (n < max && s[n] != '\0')
        n++;
    return n;
}

// Copies at most min(dst_size - 1, src_max) bytes of src, stopping at its first NUL, and zero-fills the
// rest of dst. Never reads src past src_max bytes, so unterminated sources are safe.
static __attribute__((noinline)) void copy_field(char *dst, size_t dst_size, const char *src, size_t src_max) {
    size_t limit = dst_size - 1 < src_max ? dst_size - 1 : src_max;
    size_t n = bounded_strlen(src, limit);
    memcpy(dst, src, n);
    memset(dst + n, 0, dst_size - n);
}

// Drops a UTF-8 sequence left incomplete at the end of a string cut at a byte limit, zeroing its bytes.
static __attribute__((noinline)) void utf8_trim_incomplete(char *s, size_t size) {
    size_t len = bounded_strlen(s, size);
    size_t start = len;
    while (start > 0 && len - start < 3 && ((unsigned char)s[start - 1] & 0xC0) == 0x80)
        start--;
    if (start == 0)
        return;

    unsigned char lead = (unsigned char)s[start - 1];
    size_t need;
    if (lead >= 0xC2 && lead <= 0xDF)
        need = 2;
    else if (lead >= 0xE0 && lead <= 0xEF)
        need = 3;
    else if (lead >= 0xF0 && lead <= 0xF4)
        need = 4;
    else
        return;

    if (len - (start - 1) < need)
        memset(&s[start - 1], 0, len - (start - 1));
}

static bool is_alnum(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

// 1-9 characters of [A-Za-z0-9_], NUL-terminated: safe to put in a path
static __attribute__((noinline)) bool is_path_safe_id(const char *id) {
    size_t n = 0;
    for (; n < TITLEID_LEN - 1 && id[n] != '\0'; n++) {
        if (!is_alnum(id[n]) && id[n] != '_')
            return false;
    }
    return n > 0 && id[n] == '\0';
}

// Content ID shape: XXYYYY-TTTTNNNNN_NN-LLLLLLLLLLLLLLLL (36 characters, NUL-terminated)
static __attribute__((noinline)) bool is_content_id(const char *s) {
    for (int i = 0; i < CONTENTID_LEN - 1; i++) {
        if (i == 6 || i == 19) {
            if (s[i] != '-')
                return false;
        } else if (i == 16) {
            if (s[i] != '_')
                return false;
        } else if (!is_alnum(s[i])) {
            return false;
        }
    }
    return s[CONTENTID_LEN - 1] == '\0';
}

typedef struct {
    const char *key;
    char *out;
    uint32_t out_size;
} sfo_query_t;

// Reads string values from a param.sfo. Every out buffer is zero-filled first and is NUL-terminated on
// return. Returns the number of keys found, or < 0 if the file can't be opened or isn't a valid SFO.
static int sfo_get_strings(const char *path, const sfo_query_t *queries, int nqueries) {
    for (int q = 0; q < nqueries; q++)
        memset(queries[q].out, 0, queries[q].out_size);

    SceUID fd = ksceIoOpen(path, SCE_O_RDONLY, 0);
    if (fd < 0)
        return fd;

    int found = -1;
    uint32_t done = 0;
    sfo_header_t hdr;
    if (ksceIoPread(fd, &hdr, sizeof(hdr), 0) != (int)sizeof(hdr) || hdr.magic != SFO_MAGIC)
        goto out;
    if (hdr.indexTableEntries == 0 || hdr.indexTableEntries > SFO_MAX_ENTRIES)
        goto out;

    uint32_t index_size = hdr.indexTableEntries * sizeof(sfo_entry_t);
    if (hdr.keyTableOffset < sizeof(hdr) + index_size || hdr.dataTableOffset <= hdr.keyTableOffset)
        goto out;
    if (ksceIoPread(fd, g_sfo_index, index_size, sizeof(hdr)) != (int)index_size)
        goto out;

    uint32_t keys_size = hdr.dataTableOffset - hdr.keyTableOffset;
    if (keys_size > sizeof(g_sfo_keys))
        keys_size = sizeof(g_sfo_keys);
    int ret = ksceIoPread(fd, g_sfo_keys, keys_size, hdr.keyTableOffset);
    if (ret <= 0)
        goto out;
    keys_size = (uint32_t)ret;

    found = 0;
    for (uint32_t i = 0; i < hdr.indexTableEntries; i++) {
        const sfo_entry_t *entry = &g_sfo_index[i];
        if (entry->keyOffset >= keys_size)
            continue;
        const char *key = &g_sfo_keys[entry->keyOffset];
        uint32_t key_room = keys_size - entry->keyOffset;

        for (int q = 0; q < nqueries; q++) {
            uint32_t key_len = strlen(queries[q].key) + 1; // exact match, NUL included
            if ((done & (1u << q)) || key_len > key_room || memcmp(key, queries[q].key, key_len) != 0)
                continue;

            done |= 1u << q;
            uint32_t data_offset = hdr.dataTableOffset + entry->dataOffset;
            if ((entry->param_fmt != SFO_FMT_UTF8 && entry->param_fmt != SFO_FMT_UTF8_SPECIAL) ||
                    data_offset < hdr.dataTableOffset)
                break;

            uint32_t len = entry->paramLen;
            if (len > queries[q].out_size - 1)
                len = queries[q].out_size - 1;
            if (ksceIoPread(fd, queries[q].out, len, data_offset) != (int)len) {
                memset(queries[q].out, 0, queries[q].out_size);
                break;
            }

            // Zero anything after an embedded NUL so nothing stale or raw reaches the packet
            size_t n = bounded_strlen(queries[q].out, queries[q].out_size);
            memset(queries[q].out + n, 0, queries[q].out_size - n);
            found++;
            break;
        }
    }

out:
    ksceIoClose(fd);
    return found;
}

// TITLE and CONTENT_ID of the title/bubble `id`, from the first param.sfo location that parses.
// Cached per (pid, id), so each launch costs at most one round of file I/O.
static const sfo_info_t *sfo_lookup(SceUID pid, const char *id) {
    if (g_sfo_cache.pid == pid && !strncmp(g_sfo_cache.id, id, TITLEID_LEN))
        return &g_sfo_cache;

    memset(&g_sfo_cache, 0, sizeof(g_sfo_cache));
    g_sfo_cache.pid = pid;
    copy_field(g_sfo_cache.id, TITLEID_LEN, id, TITLEID_LEN - 1);
    if (!is_path_safe_id(g_sfo_cache.id))
        return &g_sfo_cache;

    const sfo_query_t queries[] = {
        { "TITLE",      g_sfo_title,     sizeof(g_sfo_title) },
        { "CONTENT_ID", g_sfo_contentid, sizeof(g_sfo_contentid) },
    };

    for (size_t i = 0; i < sizeof(k_sfo_locations) / sizeof(k_sfo_locations[0]); i++) {
        snprintf(g_sfo_path, sizeof(g_sfo_path), "%s%s%s",
                 k_sfo_locations[i].prefix, g_sfo_cache.id, k_sfo_locations[i].suffix);
        if (sfo_get_strings(g_sfo_path, queries, sizeof(queries) / sizeof(queries[0])) < 0)
            continue;

        if (g_sfo_title[0] != '\0') {
            g_sfo_cache.has_title = true;
            copy_field(g_sfo_cache.title, TITLE_LEN, g_sfo_title, sizeof(g_sfo_title));
            utf8_trim_incomplete(g_sfo_cache.title, TITLE_LEN);
        }
        if (is_content_id(g_sfo_contentid))
            copy_field(g_sfo_cache.contentid, CONTENTID_LEN, g_sfo_contentid, sizeof(g_sfo_contentid));
        break;
    }

    return &g_sfo_cache;
}

// Copies the foreground app out of SceAppMgr's list. No I/O or cross-process access happens while its
// mutex is held. Returns slot + 1, or 0 if no app is running (LiveArea) or the mutex can't be locked.
// If there's a better way of obtaining foreground app info, please do let me know
static int get_fg_app(fg_app_t *out) {
    memset(out, 0, sizeof(*out));

    int ret = ksceKernelLockMutex(*SceAppMgr_mutex_uid, 1, NULL);
    if (ret < 0)
        return 0;

    int found = 0;
    for (int i = 0; i < APP_LIST_ENTRIES; i++) {
        uintptr_t pcurrent = (uintptr_t)SceAppMgr_app_list + (i * APP_LIST_ENTRY_SIZE);

        SceUID pid = APP_LIST_GET_PID(pcurrent);
        if (pid <= 0)
            continue;

        uint32_t state = APP_LIST_GET_STATE(pcurrent);
        if (state != APP_RUNNING)
            continue;

        const char *titleid = (const char *)(APP_LIST_GET_TITLEID(pcurrent));

        // Filter out bg stuff
        if (!strncmp(titleid, "NPXS", 4) &&
                (!strncmp(&titleid[4], "10079", 5) ||     // Daily Checker BG
                 !strncmp(&titleid[4], "10063", 5))) { // MsgMW
            continue;
        }

        out->pid = pid;
        out->is_pspemu = ksceSblACMgrIsPspEmu(pid) > 0;
        copy_field(out->titleid, TITLEID_LEN, titleid, TITLEID_LEN - 1);
        copy_field(out->bubbleid, TITLEID_LEN, (const char *)(APP_LIST_GET_BUBBLEID(pcurrent)), TITLEID_LEN - 1);
        copy_field(out->title, TITLE_LEN, (const char *)(APP_LIST_GET_TITLE(pcurrent)), TITLE_LEN - 1);
        found = i + 1;
        break;
    }

    ksceKernelUnlockMutex(*SceAppMgr_mutex_uid, 1);
    return found;
}

// Builds the packet from scratch, so no byte of an earlier packet or of kernel memory leaks into it
static void fill_packet(vitapresence_data_t *data) {
    memset(data, 0, sizeof(*data));
    data->magic = VITAPRESENCE_MAGIC;
    data->index = get_fg_app(&g_fg);
    if (data->index == 0)
        return;

    // PspEmu launched through Adrenaline
    if (g_fg.is_pspemu && !strncmp(g_fg.bubbleid, "PSPEMUCFW", 9)) {
        memset(&g_adrenaline, 0, sizeof(g_adrenaline));
        int ret = ksceKernelCopyFromUserProc(g_fg.pid, &g_adrenaline, (const void *)0x73CDE000, sizeof(SceAdrenaline));
        if (ret < 0) {
            // Report Adrenaline itself rather than whatever the buffer held
            copy_field(data->titleid, TITLEID_LEN, g_fg.bubbleid, TITLEID_LEN - 1);
            copy_field(data->title, TITLE_LEN, "Adrenaline", TITLE_LEN - 1);
        } else if (g_adrenaline.titleid[0] == '\0' || !strncmp(g_adrenaline.titleid, "XMB", 3)) {
            copy_field(data->titleid, TITLEID_LEN, "XMB", TITLEID_LEN - 1);
            copy_field(data->title, TITLE_LEN, "Adrenaline XMB Menu", TITLE_LEN - 1);
        } else {
            copy_field(data->titleid, TITLEID_LEN, g_adrenaline.titleid, sizeof(g_adrenaline.titleid));
            copy_field(data->title, TITLE_LEN, g_adrenaline.title, sizeof(g_adrenaline.title));
            utf8_trim_incomplete(data->title, TITLE_LEN);
        }
    }
    // PspEmu launched through custom bubble
    else if (g_fg.is_pspemu) {
        const sfo_info_t *sfo = sfo_lookup(g_fg.pid, g_fg.bubbleid);
        copy_field(data->titleid, TITLEID_LEN, g_fg.bubbleid, TITLEID_LEN - 1);
        if (sfo->has_title)
            copy_field(data->title, TITLE_LEN, sfo->title, TITLE_LEN);
        else
            copy_field(data->title, TITLE_LEN, g_fg.bubbleid, TITLEID_LEN - 1);
        copy_field(data->contentid, CONTENTID_LEN, sfo->contentid, CONTENTID_LEN);
    }
    // PSVita game/app
    else {
        copy_field(data->titleid, TITLEID_LEN, g_fg.titleid, TITLEID_LEN);
        copy_field(data->title, TITLE_LEN, g_fg.title, TITLE_LEN);
        utf8_trim_incomplete(data->title, TITLE_LEN);

        // System apps have no store content ID: skip the file I/O
        if (strncmp(g_fg.titleid, "NPXS", 4) != 0) {
            const sfo_info_t *sfo = sfo_lookup(g_fg.pid, g_fg.titleid);
            copy_field(data->contentid, CONTENTID_LEN, sfo->contentid, CONTENTID_LEN);
        }
    }
}

static int vitapresence_thread(SceSize args, void *argp) {
    SceUID server_sockfd = -1;
    SceUID client_sockfd = -1;

    SceNetSockaddrIn clientaddr;
    SceNetSockaddrIn serveraddr;
    memset(&serveraddr, 0, sizeof(serveraddr));
    serveraddr.sin_len = sizeof(serveraddr);
    serveraddr.sin_family = SCE_NET_AF_INET;
    serveraddr.sin_addr.s_addr = SCE_NET_INADDR_ANY;
    serveraddr.sin_port = ksceNetHtons(VITAPRESENCE_PORT);

    unsigned int addrlen = sizeof(SceNetSockaddrIn);
    int ret = 0;

    static vitapresence_data_t presence_data;

    while (g_thread_run) {
        server_sockfd = ksceNetSocket("vitapresence_socket", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
        if (server_sockfd < 0)
            return 0;
        g_server_sockfd = server_sockfd;

        do {
            if (!g_thread_run)
                break;
            ksceKernelDelayThread(2 * 1000 * 1000);
            if (!g_thread_run)
                break;

            ret = ksceNetBind(server_sockfd, (SceNetSockaddr *)&serveraddr, sizeof(SceNetSockaddrIn));
            if (ret < 0)
                continue;

            ret = ksceNetListen(server_sockfd, 128);
            if (ret < 0)
                continue;
        } while (g_thread_run && ret < 0);

        while (g_thread_run && ret >= 0) {
            client_sockfd = ksceNetAccept(server_sockfd, (SceNetSockaddr *)&clientaddr, &addrlen);
            if (client_sockfd < 0)
                break;

            fill_packet(&presence_data);

            ret = ksceNetSend(client_sockfd, &presence_data, sizeof(vitapresence_data_t), 0);
            ksceNetSocketClose(client_sockfd);
        }

        if (g_server_sockfd == server_sockfd)
            g_server_sockfd = -1;
        ksceNetSocketClose(server_sockfd);
    }

    return 0;
}

void _start() __attribute__ ((weak, alias ("module_start")));
int module_start(SceSize argc, const void *args) {

    tai_module_info_t tai_info;
    tai_info.size = sizeof(tai_module_info_t);
    if (taiGetModuleInfoForKernel(KERNEL_PID, "SceAppMgr", &tai_info) < 0)
        return SCE_KERNEL_START_NO_RESIDENT;

    // Refuse to start (rather than crash on the first connection) if SceAppMgr's data segment can't
    // hold the app list this plugin reads
    uintptr_t span_end;
    if (module_get_offset(KERNEL_PID, tai_info.modid, 1, 0x4A4, (uintptr_t *)&SceAppMgr_mutex_uid) < 0 ||
            module_get_offset(KERNEL_PID, tai_info.modid, 1, APP_LIST_OFFSET, (uintptr_t *)&SceAppMgr_app_list) < 0 ||
            module_get_offset(KERNEL_PID, tai_info.modid, 1, APP_LIST_SPAN_END, &span_end) < 0)
        return SCE_KERNEL_START_NO_RESIDENT;

    // 16 KiB: param.sfo is read on this thread
    g_thread_uid = ksceKernelCreateThread("vitapresence_thread", vitapresence_thread, 0x3C, 0x4000, 0, 0x10000, 0);
    if (g_thread_uid < 0)
        return SCE_KERNEL_START_NO_RESIDENT;

    ksceKernelStartThread(g_thread_uid, 0, NULL);
    return SCE_KERNEL_START_SUCCESS;
}

int module_stop(SceSize argc, const void *args) {
    if (g_thread_uid >= 0) {
        SceUID sock;
        SceUInt timeout = 5 * 1000 * 1000;

        g_thread_run = false;
        // accept blocks until a client connects. Closing the listener makes it return so the thread can exit.
        sock = g_server_sockfd;
        g_server_sockfd = -1;
        if (sock >= 0)
            ksceNetSocketClose(sock);
        ksceKernelWaitThreadEnd(g_thread_uid, NULL, &timeout);
        ksceKernelDeleteThread(g_thread_uid);
    }

    return SCE_KERNEL_STOP_SUCCESS;
}
