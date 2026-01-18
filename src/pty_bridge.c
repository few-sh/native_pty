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
    
    while (ctx->running) {
        ssize_t n = read(ctx->master_fd, buffer, sizeof(buffer));
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                usleep(10000); // Sleep 10ms if no data
                continue;
            }
            break; // EOF or error
        }
        
        // Allocate memory for Dart to consume
        uint8_t* out = (uint8_t*)malloc(n);
        if (out != NULL) {
            memcpy(out, buffer, n);
            // Asynchronously notify Dart
            if (ctx->callback != NULL) {
                ctx->callback(out, n);
            } else {
                // Free memory if callback is not available
                free(out);
            }
        }
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
    // On Linux, use standard waitpid
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
#endif
    
    // Notify Dart about process exit
    if (ctx->exit_callback != NULL) {
        ctx->exit_callback(exit_code);
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
        free(ctx);
        return NULL;
    }
    
    // Set master FD to non-blocking for better control
    int flags = fcntl(ctx->master_fd, F_GETFL, 0);
    fcntl(ctx->master_fd, F_SETFL, flags | O_NONBLOCK);
    
    // Prepare posix_spawn attributes
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, slave_fd);
    posix_spawn_file_actions_addclose(&actions, ctx->master_fd);
    
    // Set working directory if specified
    if (cwd != NULL) {
        #ifdef __linux__
        // Linux supports posix_spawn_file_actions_addchdir_np
        posix_spawn_file_actions_addchdir_np(&actions, cwd);
        #elif defined(__APPLE__)
        // macOS also supports this function
        posix_spawn_file_actions_addchdir_np(&actions, cwd);
        #else
        // For other systems, we can't easily change directory with posix_spawn
        // This is a limitation, but we'll document it
        #endif
    }
    
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // Create a new session - this is critical for PTY
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    
    pid_t pid;
    // Use provided environment or fall back to current process environment
    char* const* env_to_use = (envp != NULL) ? envp : environ;
    int spawn_result = posix_spawn(&pid, command, &actions, &attr, argv, env_to_use);
    
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(slave_fd);
    
    if (spawn_result != 0) {
        close(ctx->master_fd);
        free(ctx);
        return NULL;
    }
    
    ctx->pid = pid;
    
    // Start the reader thread
    pthread_t thread;
    if (pthread_create(&thread, NULL, pty_read_loop, ctx) != 0) {
        close(ctx->master_fd);
        kill(pid, SIGKILL);
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
    
    ssize_t written = write(ctx->master_fd, data, length);
    return (int)written;
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
    
    // Send the signal to the process
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
    
    ctx->running = 0;
    
    // Close the master FD to trigger thread exit
    if (ctx->master_fd >= 0) {
        close(ctx->master_fd);
    }
    
    // Wait for reader thread to finish
    if (ctx->thread != NULL) {
        pthread_join((pthread_t)ctx->thread, NULL);
    }
    
    // Kill the child process if still running
    if (ctx->pid > 0) {
        // Try graceful termination first
        kill(ctx->pid, SIGTERM);
        // Wait briefly to see if process terminates
        usleep(100000); // 100ms
        // Check if process is still running
        int status;
        if (waitpid(ctx->pid, &status, WNOHANG) == 0) {
            // Process still running, force kill
            kill(ctx->pid, SIGKILL);
        }
    }
    
    // Wait for exit monitoring thread to finish
    // This is important to avoid use-after-free
    if (ctx->exit_thread != NULL) {
        pthread_join((pthread_t)ctx->exit_thread, NULL);
    }
    
    free(ctx);
}

// Memory management functions for Dart
void* pty_malloc(size_t size) {
    return malloc(size);
}

void pty_free(void* ptr) {
    free(ptr);
}
