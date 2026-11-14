#ifndef GATEWAY_PROCESS_NATIVE_H
#define GATEWAY_PROCESS_NATIVE_H
#include <stdint.h>
#include <sys/types.h>
typedef struct {
    pid_t pid;
    int input;
    int output;
    int error;
} gwp_process;
int gwp_spawn(const char *, char *const [], char *const [], const char *, gwp_process *);
int gwp_observe_exit(pid_t);
int gwp_signal_owned_group(pid_t, int);
int gwp_reap(pid_t, int *);
int gwp_group_quiescent(pid_t);
int gwp_exit_code(int);
ssize_t gwp_write(int, const void *, size_t);
#endif
