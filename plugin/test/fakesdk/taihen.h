// Host stand-in for the parts of taihen.h that src/main.c uses. For the host test harness only.
#ifndef FAKE_TAIHEN_H
#define FAKE_TAIHEN_H

#include <vitasdkkern.h>

#define KERNEL_PID 0x10005

typedef struct _tai_module_info {
    size_t size;
    SceUID modid;
    uint32_t module_nid;
    char name[27];
    uintptr_t exports_start;
    uintptr_t exports_end;
    uintptr_t imports_start;
    uintptr_t imports_end;
} tai_module_info_t;

int taiGetModuleInfoForKernel(SceUID pid, const char *module, tai_module_info_t *info);

#endif
