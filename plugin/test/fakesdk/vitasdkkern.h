// Host stand-in for the parts of the VitaSDK kernel API that src/main.c uses (signatures as in vita-headers).
// For the host test harness only; harness.c implements the functions.
#ifndef FAKE_VITASDKKERN_H
#define FAKE_VITASDKKERN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef int SceUID;
typedef unsigned int SceSize;
typedef uint32_t SceUInt;
typedef int64_t SceOff;
typedef int SceMode;

#define SCE_O_RDONLY 0x0001

#define SCE_KERNEL_START_SUCCESS     (0)
#define SCE_KERNEL_START_NO_RESIDENT (1)
#define SCE_KERNEL_STOP_SUCCESS      (0)

typedef struct SceNetInAddr {
    unsigned int s_addr;
} SceNetInAddr;

typedef struct SceNetSockaddr {
    unsigned char sa_len;
    unsigned char sa_family;
    char sa_data[14];
} SceNetSockaddr;

typedef struct SceNetSockaddrIn {
    unsigned char sin_len;
    unsigned char sin_family;
    unsigned short int sin_port;
    SceNetInAddr sin_addr;
    unsigned short int sin_vport;
    char sin_zero[6];
} SceNetSockaddrIn;

#define SCE_NET_AF_INET     2
#define SCE_NET_SOCK_STREAM 1
#define SCE_NET_INADDR_ANY  0x00000000

typedef int (*SceKernelThreadEntry)(SceSize args, void *argp);
typedef struct SceKernelThreadOptParam SceKernelThreadOptParam;

SceUID ksceIoOpen(const char *file, int flags, SceMode mode);
int ksceIoClose(SceUID fd);
int ksceIoPread(SceUID fd, void *data, SceSize size, SceOff offset);

int ksceKernelLockMutex(SceUID mutexid, int lockCount, unsigned int *timeout);
int ksceKernelUnlockMutex(SceUID mutexid, int unlockCount);
int ksceKernelCopyFromUserProc(SceUID pid, void *dst, const void *src, SceSize len);
int ksceSblACMgrIsPspEmu(SceUID pid);

SceUID ksceKernelCreateThread(const char *name, SceKernelThreadEntry entry, int initPriority,
                              SceSize stackSize, SceUInt attr, int cpuAffinityMask,
                              const SceKernelThreadOptParam *option);
int ksceKernelStartThread(SceUID thid, SceSize arglen, void *argp);
int ksceKernelWaitThreadEnd(SceUID thid, int *stat, SceUInt *timeout);
int ksceKernelDeleteThread(SceUID thid);
int ksceKernelDelayThread(SceUInt delay);

int ksceNetSocket(const char *name, int domain, int type, int protocol);
int ksceNetBind(int s, const SceNetSockaddr *addr, unsigned int addrlen);
int ksceNetListen(int s, int backlog);
int ksceNetAccept(int s, SceNetSockaddr *addr, unsigned int *addrlen);
int ksceNetSendto(int s, const void *msg, unsigned int len, int flags, const SceNetSockaddr *to, unsigned int tolen);
int ksceNetClose(int s);
#define ksceNetSend(s, msg, len, flags) ksceNetSendto(s, msg, len, flags, NULL, 0)
#define ksceNetSocketClose ksceNetClose
#define ksceNetHtons __builtin_bswap16

#endif
