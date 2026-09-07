#define _GNU_SOURCE
#include "GatewayProcessNative.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#else
#include <dirent.h>
#endif

static int owned_pipe(int pair[2]) {
    int temporary[2];
#ifdef __linux__
    if (pipe2(temporary, O_CLOEXEC)) return errno;
#else
    if (pipe(temporary)) return errno;
#endif
    pair[0] = fcntl(temporary[0], F_DUPFD_CLOEXEC, 3);
    pair[1] = fcntl(temporary[1], F_DUPFD_CLOEXEC, 3);
    int error = (pair[0] < 0 || pair[1] < 0) ? errno : 0;
    close(temporary[0]); close(temporary[1]);
    if (error) { if (pair[0] >= 0) close(pair[0]); if (pair[1] >= 0) close(pair[1]); pair[0] = pair[1] = -1; }
    return error;
}

int gwp_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd, gwp_process *result) {
    int descriptors[6] = {-1, -1, -1, -1, -1, -1};
    int error = 0;
    *result = (gwp_process){0, -1, -1, -1};
    struct sigaction child_action;
    if (sigaction(SIGCHLD, NULL, &child_action)) return errno;
    if (child_action.sa_handler == SIG_IGN || (child_action.sa_flags & SA_NOCLDWAIT)) return EINVAL;
    for (int index = 0; index < 6; index += 2) {
        error = owned_pipe(&descriptors[index]);
        if (error) goto close_descriptors;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    error = posix_spawn_file_actions_init(&actions);
    if (error) goto close_descriptors;
    error = posix_spawnattr_init(&attributes);
    if (error) { posix_spawn_file_actions_destroy(&actions); goto close_descriptors; }
#define CHECK(call) do { error = (call); if (error) goto destroy_attributes; } while (0)
    CHECK(posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, descriptors[3], STDOUT_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, descriptors[5], STDERR_FILENO));
    for (int index = 0; index < 6; index++) CHECK(posix_spawn_file_actions_addclose(&actions, descriptors[index]));
    if (cwd) CHECK(posix_spawn_file_actions_addchdir_np(&actions, cwd));
    sigset_t mask, defaults;
    sigemptyset(&mask); sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGPIPE);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
#ifdef __APPLE__
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    CHECK(posix_spawnattr_setflags(&attributes, flags));
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    CHECK(posix_spawnattr_setsigmask(&attributes, &mask));
    CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    CHECK(posix_spawn(&result->pid, path, &actions, &attributes, argv, envp));
    result->input = descriptors[1]; result->output = descriptors[2]; result->error = descriptors[4];
    descriptors[1] = descriptors[2] = descriptors[4] = -1;
destroy_attributes:
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
close_descriptors:
    for (int index = 0; index < 6; index++) if (descriptors[index] >= 0) close(descriptors[index]);
    return error;
#undef CHECK
}

int gwp_observe_exit(pid_t pid) {
    siginfo_t information;
    memset(&information, 0, sizeof information);
    int result;
    do { result = waitid(P_PID, (id_t)pid, &information, WEXITED | WNOHANG | WNOWAIT); } while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    return information.si_pid == pid ? 1 : 0;
}

int gwp_signal_owned_group(pid_t pid, int signal_number) {
    // The runner is the sole wait owner. WNOWAIT pins the PID/PGID through
    // every signal; no timer or cancellation callback signals a numeric PID.
    int observed = gwp_observe_exit(pid);
    if (observed < 0) return -observed;
    if (kill(-pid, signal_number) == 0 || errno == ESRCH) return 0;
    int failure = errno;
    // Darwin returns EPERM for a group containing only zombies.
    if (failure == EPERM && gwp_group_quiescent(pid) == 1) return 0;
    return failure;
}

int gwp_reap(pid_t pid, int *status) {
    pid_t result;
    do { result = waitpid(pid, status, 0); } while (result < 0 && errno == EINTR);
    return result == pid ? 0 : errno;
}

int gwp_exit_code(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

// The unreaped leader reserves the group ID while this snapshot is taken.
// Once no live member remains, no member can create additional children.
int gwp_group_quiescent(pid_t group) {
#ifdef __APPLE__
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group};
    for (;;) {
        size_t size = 0;
        if (sysctl(query, 4, NULL, &size, NULL, 0)) return -errno;
        size += 16 * sizeof(struct kinfo_proc);
        struct kinfo_proc *processes = malloc(size);
        if (!processes) return -ENOMEM;
        if (sysctl(query, 4, processes, &size, NULL, 0)) {
            int failure = errno;
            free(processes);
            if (failure == ENOMEM) continue;
            return -failure;
        }
        int quiet = 1;
        for (size_t index = 0; index < size / sizeof(*processes); index++) {
            if (processes[index].kp_proc.p_stat != SZOMB) { quiet = 0; break; }
        }
        free(processes);
        return quiet;
    }
#else
    DIR *directory = opendir("/proc");
    if (!directory) return -errno;
    struct dirent *entry;
    int quiet = 1;
    while ((entry = readdir(directory))) {
        char *end;
        long identifier = strtol(entry->d_name, &end, 10);
        if (*end || identifier <= 0) continue;
        char path[80], line[4096];
        snprintf(path, sizeof path, "/proc/%ld/stat", identifier);
        FILE *file = fopen(path, "r");
        if (!file) {
            if (errno == ENOENT || errno == ESRCH) continue;
            quiet = -errno; break;
        }
        char *read_result = fgets(line, sizeof line, file);
        fclose(file);
        if (!read_result) { quiet = -EIO; break; }
        char *name_end = strrchr(line, ')');
        char state;
        long parent, process_group;
        if (!name_end || sscanf(name_end + 1, " %c %ld %ld", &state, &parent, &process_group) != 3) {
            quiet = -EIO; break;
        }
        if (process_group == group && state != 'Z' && state != 'X') { quiet = 0; break; }
    }
    closedir(directory);
    return quiet;
#endif
}

ssize_t gwp_write(int descriptor, const void *data, size_t size) {
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    int failure = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (failure) { errno = failure; return -1; }
    sigpending(&pending);
    ssize_t result = write(descriptor, data, size);
    int saved_errno = errno;
    if (result < 0 && saved_errno == EPIPE && !sigismember(&pending, SIGPIPE)) {
        sigpending(&pending);
        if (sigismember(&pending, SIGPIPE)) {
            int received = 0;
            sigwait(&blocked, &received);
        }
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    errno = saved_errno;
    return result;
}
