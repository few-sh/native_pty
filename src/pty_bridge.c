#define _GNU_SOURCE
#include "pty_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#ifdef __APPLE__
#include <util.h>
#include <sys/event.h>
#else
#include <pty.h>
#endif
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <spawn.h>
#include <errno.h>

extern char **environ;

// Thread function for reading PTY output
static void* pty_read_loop(void* args) {
    PtyContext* ctx = (PtyContext*)args;
    uint8_t buffer[4096];
    
    // Read until EOF - do NOT check running flag here
    // The reader must drain all data until the child closes its end
    while (1) {
        ssize_t n = read(ctx->master_fd, buffer, sizeof(buffer));
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                usleep(10000); // Sleep 10ms if no data
                continue;
            }
            break; // EOF or error
        }
        
        // Copy the callback pointer under mutex protection
        // This prevents calling the callback after it's been closed
        pthread_mutex_t* mutex = (pthread_mutex_t*)ctx->mutex;
        pthread_mutex_lock(mutex);
        PtyDataCallback callback = ctx->callback;
        pthread_mutex_unlock(mutex);
        
        // Now perform the allocation and callback invocation outside the critical section
        if (callback != NULL) {
            uint8_t* out = (uint8_t*)malloc(n);
            if (out != NULL) {
                memcpy(out, buffer, n);
                callback(out, n);
            }
        }
    }
    
    // Mark reading as finished and check if we need to fire exit callback
    // This synchronization ensures exit callback is not fired until all data has been read
    pthread_mutex_t* mutex = (pthread_mutex_t*)ctx->mutex;
    pthread_mutex_lock(mutex);
    ctx->read_finished = 1;
    int should_fire_exit = ctx->has_exited;
    int code = ctx->exit_code;
    PtyExitCallback exit_callback = ctx->exit_callback;
    pthread_mutex_unlock(mutex);
    
    if (should_fire_exit && exit_callback != NULL) {
        exit_callback(code);
    }
    
    return NULL;
}

// Thread function for monitoring process exit
static void* pty_exit_monitor(void* args) {
    PtyContext* ctx = (PtyContext*)args;
    int exit_code = 0;
    
#ifdef __APPLE__
    // On macOS, use kqueue to monitor process exit
    // This is more reliable than waitpid when other code (like Dart VM) 
    // might also be waiting for children
    int kq = kqueue();
    if (kq >= 0) {
        struct kevent change;
        struct kevent event;
        
        // Register interest in EVFILT_PROC for NOTE_EXIT and NOTE_EXITSTATUS
        // NOTE_EXITSTATUS makes event.data contain the exit status directly
        EV_SET(&change, ctx->pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, 
               NOTE_EXIT | NOTE_EXITSTATUS, 0, NULL);
        
        // Wait for the event
        int nev = kevent(kq, &change, 1, &event, 1, NULL);
        
        close(kq);
        
        if (nev > 0 && (event.fflags & NOTE_EXIT)) {
            // On macOS with NOTE_EXITSTATUS, event.data contains the exit status
            // in the format that can be decoded with WIFEXITED/WEXITSTATUS macros
            if (event.fflags & NOTE_EXITSTATUS) {
                int status = (int)event.data;
                if (WIFEXITED(status)) {
                    exit_code = WEXITSTATUS(status);
                } else if (WIFSIGNALED(status)) {
                    exit_code = 128 + WTERMSIG(status);
                } else {
                    exit_code = -1;
                }
                // Reap the zombie process confirmed by kqueue
                waitpid(ctx->pid, NULL, WNOHANG);
            } else {
                // Fallback: try to get status from waitpid
                int status;
                pid_t result = waitpid(ctx->pid, &status, WNOHANG);
                if (result > 0) {
                    if (WIFEXITED(status)) {
                        exit_code = WEXITSTATUS(status);
                    } else if (WIFSIGNALED(status)) {
                        exit_code = 128 + WTERMSIG(status);
                    } else {
                        exit_code = -1;
                    }
                } else {
                    // Child was reaped by something else, can't get exit code
                    exit_code = -1;
                }
            }
        } else {
            exit_code = -1;
        }
    } else {
        // Fallback to waitpid if kqueue fails
        int status;
        pid_t result;
        int saved_errno;
        do {
            result = waitpid(ctx->pid, &status, 0);
            saved_errno = errno;
        } while (result == -1 && saved_errno == EINTR);
        
        if (result > 0) {
            if (WIFEXITED(status)) {
                exit_code = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                exit_code = 128 + WTERMSIG(status);
            } else {
                exit_code = -1;
            }
        } else {
            exit_code = -1;
        }
    }
#else
    // On Linux, use the exit_fd pipe from the Monitor process
    if (ctx->exit_fd != -1) {
        int code = -1;
        ssize_t n = read(ctx->exit_fd, &code, sizeof(int));
        if (n == sizeof(int)) {
            exit_code = code;
        } else {
            exit_code = -1;
        }
        close(ctx->exit_fd);
        ctx->exit_fd = -1;
    } else {
        // Fallback or legacy (should not happen with new spawn)
        exit_code = -1;
    }
#endif
    
    // Notify Dart about process exit ONLY if reading is also finished.
    // Otherwise, store state and let reader thread notify when it's done.
    pthread_mutex_t* mutex = (pthread_mutex_t*)ctx->mutex;
    pthread_mutex_lock(mutex);
    ctx->has_exited = 1;
    ctx->exit_code = exit_code;
    int should_fire_exit = ctx->read_finished;
    PtyExitCallback exit_callback = ctx->exit_callback;
    pthread_mutex_unlock(mutex);
    
    // If reader finished first, we fire the callback now
    if (should_fire_exit && exit_callback != NULL) {
        exit_callback(exit_code);
    }
    
    return NULL;
}

// Initialize the PTY system
void pty_init() {
    // Don't ignore SIGCHLD - we need to wait for child processes
    // to get their exit codes
}

// Helper function to apply terminal mode settings
static void apply_terminal_mode(struct termios* term_settings, int mode) {
    switch (mode) {
        case PTY_MODE_CANONICAL:
            // Canonical mode: line buffering, echoing, signal processing
            term_settings->c_lflag |= ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | ISIG | IEXTEN;
            term_settings->c_iflag |= ICRNL | IXON;
            term_settings->c_oflag |= OPOST | ONLCR;
            break;
            
        case PTY_MODE_CBREAK:
            // Cbreak mode: character-at-a-time, echoing, signal processing
            term_settings->c_lflag &= ~ICANON;  // Disable canonical mode
            term_settings->c_lflag |= ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | ISIG | IEXTEN;
            term_settings->c_iflag |= ICRNL | IXON;
            term_settings->c_oflag |= OPOST | ONLCR;
            term_settings->c_cc[VMIN] = 1;   // Read at least 1 character
            term_settings->c_cc[VTIME] = 0;  // No timeout
            break;
            
        case PTY_MODE_RAW:
            // Raw mode: no processing, no echoing, no signals
            // Disable canonical mode, echoing, and signal generation
            term_settings->c_lflag &= ~(ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | ISIG | IEXTEN);
            // Disable input processing
            term_settings->c_iflag &= ~(ICRNL | IXON | IXOFF | INLCR | IGNCR | BRKINT | INPCK | ISTRIP);
            // Disable output processing
            term_settings->c_oflag &= ~(OPOST | ONLCR);
            // Set character size to 8 bits
            term_settings->c_cflag |= CS8;
            term_settings->c_cflag &= ~PARENB;
            term_settings->c_cc[VMIN] = 1;   // Read at least 1 character
            term_settings->c_cc[VTIME] = 0;  // No timeout
            break;
    }
}

// Spawn a new process with PTY
PtyContext* pty_spawn(const char* command, char* const argv[], char* const envp[], const char* cwd, int mode, PtyDataCallback callback, PtyExitCallback exit_callback) {
    if (command == NULL || argv == NULL || callback == NULL) {
        return NULL;
    }
    
    PtyContext* ctx = (PtyContext*)malloc(sizeof(PtyContext));
    if (ctx == NULL) {
        return NULL;
    }
    
    memset(ctx, 0, sizeof(PtyContext));
    ctx->callback = callback;
    ctx->exit_callback = exit_callback;
    ctx->running = 1;
    ctx->mode = mode;  // Store the requested mode
    
    // Initialize synchronization primitives - REQUIRED for thread safety
    ctx->mutex = malloc(sizeof(pthread_mutex_t));
    if (ctx->mutex == NULL) {
        free(ctx);
        return NULL;
    }
    pthread_mutex_init((pthread_mutex_t*)ctx->mutex, NULL);
    
    int slave_fd;
    struct termios term_settings;
    struct winsize win_size;
    
    // Set default terminal size
    win_size.ws_row = 24;
    win_size.ws_col = 80;
    win_size.ws_xpixel = 0;
    win_size.ws_ypixel = 0;
    
    // Get default terminal settings
    if (tcgetattr(STDIN_FILENO, &term_settings) == 0) {
        // Use current terminal settings as a base
    } else {
        // Set sane defaults as a base
        memset(&term_settings, 0, sizeof(term_settings));
        term_settings.c_iflag = ICRNL | IXON;
        term_settings.c_oflag = OPOST | ONLCR;
        term_settings.c_cflag = CS8 | CREAD | CLOCAL;
        term_settings.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN;
        cfsetispeed(&term_settings, B38400);
        cfsetospeed(&term_settings, B38400);
    }
    
    // Apply the requested terminal mode
    apply_terminal_mode(&term_settings, mode);
    
    // Create PTY pair
    if (openpty(&ctx->master_fd, &slave_fd, NULL, &term_settings, &win_size) != 0) {
        pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
        free(ctx->mutex);
        free(ctx);
        return NULL;
    }
    
    // Set master FD to non-blocking for better control
    int flags = fcntl(ctx->master_fd, F_GETFL, 0);
    fcntl(ctx->master_fd, F_SETFL, flags | O_NONBLOCK);
    
#ifdef __linux__
    // Linux Double-Fork Implementation to avoid Dart VM reaping children
    int exit_pipe[2];
    if (pipe(exit_pipe) != 0) {
        close(ctx->master_fd);
        close(slave_fd);
        pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
        free(ctx->mutex);
        free(ctx);
        return NULL;
    }
    
    int error_pipe[2];
    if (pipe(error_pipe) != 0) {
        close(exit_pipe[0]); close(exit_pipe[1]);
        close(ctx->master_fd);
        close(slave_fd);
        pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
        free(ctx->mutex);
        free(ctx);
        return NULL;
    }
    fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t monitor_pid = fork();
    if (monitor_pid < 0) {
        close(error_pipe[0]); close(error_pipe[1]);
        close(exit_pipe[0]); close(exit_pipe[1]);
        close(ctx->master_fd);
        close(slave_fd);
        pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
        free(ctx->mutex);
        free(ctx);
        return NULL;
    }

    if (monitor_pid == 0) {
        // Monitor Process
        close(exit_pipe[0]); // Close read end
        close(error_pipe[0]); // Close error read end
        close(ctx->master_fd);

        pid_t shell_pid = fork();
        if (shell_pid == 0) {
            // Shell Process
            close(exit_pipe[1]);
            
            // Setup session and controlling terminal
            setsid();
            if (ioctl(slave_fd, TIOCSCTTY, NULL) == -1) {}
            
            dup2(slave_fd, STDIN_FILENO);
            dup2(slave_fd, STDOUT_FILENO);
            dup2(slave_fd, STDERR_FILENO);
            if (slave_fd > STDERR_FILENO) close(slave_fd);

            if (cwd != NULL) chdir(cwd);
            
            // We need to set environ manually if we use execvp and want to replace it? 
            // Actually execvp uses current 'environ'. 
            // But we should set it if envp is provided.
            if (envp != NULL) environ = (char**)envp;
            
            execvp(command, argv);
            
            // If execvp fails, write errno to error pipe and exit
            int err = errno;
            write(error_pipe[1], &err, sizeof(int));
            _exit(1);
        }
        
        // Back in Monitor
        close(slave_fd);
        close(error_pipe[1]); // Close write end so Parent gets EOF if exec succeeds
        
        if (shell_pid < 0) {
             pid_t fail_pid = -1;
             write(exit_pipe[1], &fail_pid, sizeof(pid_t));
             _exit(1);
        }

        // Send Shell PID
        write(exit_pipe[1], &shell_pid, sizeof(pid_t));

        // Wait for shell
        int status;
        while (waitpid(shell_pid, &status, 0) == -1 && errno == EINTR);

        int exit_code = -1;
        if (WIFEXITED(status)) {
            exit_code = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            exit_code = 128 + WTERMSIG(status);
        }
        
        write(exit_pipe[1], &exit_code, sizeof(int));
        _exit(0);
    }

    // Parent (Dart)
    close(slave_fd);
    close(exit_pipe[1]); // Close write end
    close(error_pipe[1]); // Close write end of error pipe
    
    // Check for exec error
    int exec_err = 0;
    ssize_t err_read = read(error_pipe[0], &exec_err, sizeof(int));
    close(error_pipe[0]);
    
    if (err_read > 0) {
        // Exec failed
        close(exit_pipe[0]);
        close(ctx->master_fd);
        pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
        free(ctx->mutex);
        free(ctx);
        errno = exec_err;
        return NULL;
    }
    
    pid_t shell_pid = -1;
    if (read(exit_pipe[0], &shell_pid, sizeof(pid_t)) != sizeof(pid_t) || shell_pid < 0) {
        close(exit_pipe[0]);
        close(ctx->master_fd);
        pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
        free(ctx->mutex);
        free(ctx);
        return NULL;
    }
    
    ctx->pid = shell_pid;
    ctx->exit_fd = exit_pipe[0];

#else
    // Original posix_spawn Implementation for macOS/Other
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, slave_fd);
    posix_spawn_file_actions_addclose(&actions, ctx->master_fd);
    
    if (cwd != NULL) {
        #if defined(__APPLE__)
        posix_spawn_file_actions_addchdir(&actions, cwd);
        #endif
    }
    
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    
    pid_t pid;
    char* const* env_to_use = (envp != NULL) ? envp : environ;
    int spawn_result = posix_spawn(&pid, command, &actions, &attr, argv, env_to_use);
    
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(slave_fd);
    
    if (spawn_result != 0) {
        close(ctx->master_fd);
        if (ctx->mutex != NULL) {
            pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
            free(ctx->mutex);
        }
        free(ctx);
        return NULL;
    }
    
    ctx->pid = pid;
    ctx->exit_fd = -1;
#endif
    
    // Start the reader thread
    pthread_t thread;
    if (pthread_create(&thread, NULL, pty_read_loop, ctx) != 0) {
        close(ctx->master_fd);
        if (ctx->pid > 0) kill(ctx->pid, SIGKILL);
        pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
        free(ctx->mutex);
        free(ctx);
        return NULL;
    }
    
    ctx->thread = (void*)thread;
    
    // Start the exit monitoring thread if exit callback is provided
    if (ctx->exit_callback != NULL) {
        pthread_t exit_thread;
        if (pthread_create(&exit_thread, NULL, pty_exit_monitor, ctx) == 0) {
            // Don't detach - we need to join it in close() to avoid use-after-free
            ctx->exit_thread = (void*)exit_thread;
        }
    }
    
    return ctx;
}

// Write data to the PTY
int pty_write(PtyContext* ctx, const uint8_t* data, int length) {
    if (ctx == NULL || data == NULL || length <= 0) {
        return -1;
    }
    
    // Handle partial writes in a loop
    // PTY master is non-blocking, so write() may not write all data at once
    int total_written = 0;
    const uint8_t* ptr = data;
    int remaining = length;
    
    while (remaining > 0) {
        ssize_t written = write(ctx->master_fd, ptr, remaining);
        
        if (written < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Buffer full, wait a bit and retry
                usleep(1000); // 1ms
                continue;
            }
            // Real error
            return -1;
        }
        
        if (written == 0) {
            // Should not happen, but break to avoid infinite loop
            break;
        }
        
        total_written += written;
        ptr += written;
        remaining -= written;
    }
    
    return total_written;
}

// Resize the PTY window
int pty_resize(PtyContext* ctx, int rows, int cols) {
    if (ctx == NULL || rows <= 0 || cols <= 0) {
        return -1;
    }
    
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    
    return ioctl(ctx->master_fd, TIOCSWINSZ, &ws);
}

// Send a signal to the PTY process
int pty_kill(PtyContext* ctx, int signal) {
    if (ctx == NULL || ctx->pid <= 0) {
        return -1;
    }
    
    // For SIGKILL and SIGTERM, we need to kill all descendant processes.
    // Since the PTY shell is a session leader (created via setsid()), child processes
    // may create their own process groups. To kill everything, we use a two-step approach:
    // 1. Kill the entire session by closing the PTY master (sends SIGHUP to all processes)
    // 2. Send the signal to the process group and specific PID
    
    if (signal == SIGKILL || signal == SIGTERM) {
        // For terminal signals (SIGINT, SIGTSTP, etc.), we should send them to
        // the foreground process group via tcgetpgrp() to target the right job.
        // But for SIGTERM/SIGKILL, we want to kill everything.
        
        // Try to get the foreground process group
        pid_t fg_pgid = tcgetpgrp(ctx->master_fd);
        if (fg_pgid > 0 && fg_pgid != ctx->pid) {
            // Kill the foreground process group first
            kill(-fg_pgid, signal);
        }
    }
    
    // Send the signal to the process group (negative PID)
    // This ensures that we kill the entire process tree (e.g. shell + commands)
    // and works even if the leader process has already exited but children remain.
    if (kill(-ctx->pid, signal) == 0) {
        return 0;
    }
    
    // Fallback to sending to the specific PID if process group signal fails
    if (kill(ctx->pid, signal) == 0) {
        return 0;
    }
    
    return -1;
}

// Set the terminal mode
int pty_set_mode(PtyContext* ctx, int mode) {
    if (ctx == NULL || ctx->master_fd < 0) {
        return -1;
    }
    
    // Validate mode
    if (mode < PTY_MODE_CANONICAL || mode > PTY_MODE_RAW) {
        return -1;
    }
    
    struct termios term_settings;
    
    // Get current terminal settings
    if (tcgetattr(ctx->master_fd, &term_settings) != 0) {
        return -1;
    }
    
    // Apply the requested terminal mode
    apply_terminal_mode(&term_settings, mode);
    
    // Set the new terminal settings
    if (tcsetattr(ctx->master_fd, TCSANOW, &term_settings) != 0) {
        return -1;
    }
    
    // Update the stored mode
    ctx->mode = mode;
    
    return 0;
}

// Get the current terminal mode
int pty_get_mode(PtyContext* ctx) {
    if (ctx == NULL) {
        return -1;
    }
    
    return ctx->mode;
}

// Close and cleanup the PTY
void pty_close(PtyContext* ctx) {
    if (ctx == NULL) {
        return;
    }
    
    pthread_t current_thread = pthread_self();
    
    // Step 1: Stop accepting new operations
    atomic_store(&ctx->running, 0);
    
    // Step 2: Close the master FD to signal EOF to child
    // This causes the child to exit, and when it closes its PTY end, 
    // the reader will see EOF and exit naturally
    if (ctx->master_fd >= 0) {
        close(ctx->master_fd);
        ctx->master_fd = -1;
    }
    
    // Step 3: Wait for reader thread to finish draining all data
    // It will exit when it sees EOF (read returns 0)
    pthread_t reader_thread = (pthread_t)ctx->thread;
    if (ctx->thread != NULL) {
        if (pthread_equal(current_thread, reader_thread)) {
            // Called from within reader thread - detach and let it exit naturally
            pthread_detach(reader_thread);
        } else {
            // Called from different thread - wait for reader to finish
            pthread_join(reader_thread, NULL);
        }
    }
    
    // Step 4: Kill the process if still running (shouldn't happen normally)
    if (ctx->pid > 0) {
        int status;
        pid_t result = waitpid(ctx->pid, &status, WNOHANG);
        if (result == 0) {
            // Still running, force kill
            kill(ctx->pid, SIGKILL);
            waitpid(ctx->pid, &status, 0);
        }
    }
    
    // Step 5: Wait for the exit monitoring thread to finish
    pthread_t exit_thread = (pthread_t)ctx->exit_thread;
    if (ctx->exit_thread != NULL) {
        if (pthread_equal(current_thread, exit_thread)) {
            // Called from within exit thread - detach
            pthread_detach(exit_thread);
        } else {
            // Wait for exit thread to finish
            pthread_join(exit_thread, NULL);
        }
    }
    
    // Step 6: Clean up
    pthread_mutex_destroy((pthread_mutex_t*)ctx->mutex);
    free(ctx->mutex);
    
    free(ctx);
}

// Get the exit code of the process (blocks until process exits)
// Memory management functions for Dart
void* pty_malloc(size_t size) {
    return malloc(size);
}

void pty_free(void* ptr) {
    free(ptr);
}
