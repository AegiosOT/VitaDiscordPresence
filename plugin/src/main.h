#ifndef _MAIN_H_
#define _MAIN_H_

#include <stddef.h>
#include <stdint.h>

#define VITAPRESENCE_PORT  0xCAFE
#define VITAPRESENCE_MAGIC 0xCAFECAFE

#define GET_OFFSET(base, offset) (uint32_t *)((uintptr_t)(base) + (offset))
#define APP_LIST_GET_BUBBLEID(base)  GET_OFFSET(base, 0x558)
#define APP_LIST_GET_PID(base)      *GET_OFFSET(base, 0x578)
#define APP_LIST_GET_TITLE(base)     GET_OFFSET(base, 0x62C)
#define APP_LIST_GET_TITLEID(base)   GET_OFFSET(base, 0x900)
#define APP_LIST_GET_STATE(base)    *GET_OFFSET(base, 0xAA0)

#define APP_LIST_OFFSET      0x500
#define APP_LIST_ENTRIES     20
#define APP_LIST_ENTRY_SIZE  0x2410
// End of the last field read from SceAppMgr's data segment (state of the last entry)
#define APP_LIST_SPAN_END    (APP_LIST_OFFSET + (APP_LIST_ENTRIES - 1) * APP_LIST_ENTRY_SIZE + 0xAA0 + 4)

#define TITLEID_LEN   10
#define TITLE_LEN     128
#define CONTENTID_LEN 37 // 36-character content ID + NUL

typedef enum {
    APP_RUNNING = 2,
    APP_SUSPENDED = 3
} app_state_t;

// Sent as is (little-endian, 184 bytes) on every connection. Bytes 0..145 are the v1.0 packet, which old
// clients read. contentid is new in v1.1, at the offset Electry/VitaPresence PR #13 gave it.
typedef struct {
    uint32_t magic;                    // 0    VITAPRESENCE_MAGIC
    int32_t  index;                    // 4    0 = LiveArea, else app slot + 1
    char     titleid[TITLEID_LEN];     // 8
    char     title[TITLE_LEN];         // 18   UTF-8
    char     contentid[CONTENTID_LEN]; // 146  XXYYYY-TTTTNNNNN_NN-LLLLLLLLLLLLLLLL, or empty
} vitapresence_data_t;                 // 183, plus 1 byte of tail padding (zero)

_Static_assert(offsetof(vitapresence_data_t, title) == 18, "v1.0 layout");
_Static_assert(offsetof(vitapresence_data_t, contentid) == 146, "PR #13 layout");
_Static_assert(sizeof(vitapresence_data_t) == 184, "wire size");

typedef struct {
	int savestate_mode;
	int num;
	unsigned int sp;
	unsigned int ra;

	int pops_mode;
	int draw_psp_screen_in_pops;
	char title[128];
	char titleid[12];
	char filename[256];

	int psp_cmd;
	int vita_cmd;
	int psp_response;
	int vita_response;
} SceAdrenaline;

typedef struct {
	uint32_t magic;
	uint32_t version;
	uint32_t keyTableOffset;
	uint32_t dataTableOffset;
	uint32_t indexTableEntries;
} sfo_header_t;

typedef struct {
	uint16_t keyOffset;
	uint16_t param_fmt;
	uint32_t paramLen;
	uint32_t paramMaxLen;
	uint32_t dataOffset;
} sfo_entry_t;

#endif
