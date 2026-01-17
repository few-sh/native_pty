#define _GNU_SOURCE
#include "pty_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <pty.h>
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

// Initialize the PTY system
void pty_init() {
    // Ignore SIGCHLD to avoid zombie processes
    signal(SIGCHLD, SIG_IGN);
}

// Spawn a new process with PTY
PtyContext* pty_spawn(const char* command, char* const argv[], PtyDataCallback callback) {
    if (command == NULL || argv == NULL || callback == NULL) {
        return NULL;
    }
    
    PtyContext* ctx = (PtyContext*)malloc(sizeof(PtyContext));
    if (ctx == NULL) {
        return NULL;
    }
    
    memset(ctx, 0, sizeof(PtyContext));
    ctx->callback = callback;
    ctx->running = 1;
    
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
        // Use current terminal settings if available
    } else {
        // Set sane defaults
        memset(&term_settings, 0, sizeof(term_settings));
        term_settings.c_iflag = ICRNL | IXON;
        term_settings.c_oflag = OPOST | ONLCR;
        term_settings.c_cflag = CS8 | CREAD | CLOCAL;
        term_settings.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN;
        cfsetispeed(&term_settings, B38400);
        cfsetospeed(&term_settings, B38400);
    }
    
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
    
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // Create a new session - this is critical for PTY
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    
    pid_t pid;
    int spawn_result = posix_spawn(&pid, command, &actions, &attr, argv, environ);
    
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
    
    // Wait for thread to finish
    if (ctx->thread != NULL) {
        pthread_join((pthread_t)ctx->thread, NULL);
    }
    
    // Kill the child process if still running
    if (ctx->pid > 0) {
        int status;
        // Try graceful termination first
        kill(ctx->pid, SIGTERM);
        // Wait briefly to see if process terminates
        usleep(100000); // 100ms
        // Check if process is still running
        if (waitpid(ctx->pid, &status, WNOHANG) == 0) {
            // Process still running, force kill
            kill(ctx->pid, SIGKILL);
            waitpid(ctx->pid, &status, 0);
        }
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
