#ifndef MUXY_PTY_H
#define MUXY_PTY_H

int muxy_forkpty_exec(
    const char *working_directory,
    const char *shell,
    const char *command,
    char *const environment[],
    unsigned short cols,
    unsigned short rows,
    int *out_master_fd
);

int muxy_spawn_detached(const char *executable_path, const char *argument);

#endif
