#include "include/muxy_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

int muxy_forkpty_exec(
    const char *working_directory,
    const char *shell,
    const char *command,
    char *const environment[],
    unsigned short cols,
    unsigned short rows,
    int *out_master_fd
) {
    struct winsize size;
    size.ws_row = rows;
    size.ws_col = cols;
    size.ws_xpixel = 0;
    size.ws_ypixel = 0;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        if (working_directory != NULL) {
            (void)chdir(working_directory);
        }
        execle(shell, shell, "-c", command, (char *)NULL, environment);
        _exit(127);
    }
    *out_master_fd = master;
    return (int)pid;
}

int muxy_spawn_detached(const char *executable_path, const char *argument) {
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    short flags = POSIX_SPAWN_SETSID;
    if (posix_spawnattr_setflags(&attributes, flags) != 0) {
        posix_spawnattr_destroy(&attributes);
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int dev_null = open("/dev/null", O_RDWR);
    if (dev_null >= 0) {
        posix_spawn_file_actions_adddup2(&actions, dev_null, STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&actions, dev_null, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, dev_null, STDERR_FILENO);
    }

    char *const argv[] = {
        (char *)executable_path,
        (char *)argument,
        NULL,
    };

    pid_t pid = 0;
    int result = posix_spawn(&pid, executable_path, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (dev_null >= 0) {
        close(dev_null);
    }
    if (result != 0) {
        return -1;
    }
    return (int)pid;
}
