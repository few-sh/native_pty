#ifndef PTY_BRIDGE_H
#define PTY_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

// Terminal mode enum
enum PtyMode {
    PTY_MODE_CANONICAL = 0,  // Line buffering, echoing, signal processing
    PTY_MODE_CBREAK = 1,     // Character-at-a-time, echoing, signal processing
    PTY_MODE_RAW = 2         // Raw mode, no processing
};

// Callback signature for data received from PTY
typedef void (*PtyDataCallback)(uint8_t* data, int32_t length);

// Callback signature for process exit notification
typedef void (*PtyExitCallback)(int32_t exit_code);

// Context structure for PTY management
typedef struct {
    int master_fd;
    int pid;
    _Atomic int running;
    int mode;  // Current terminal mode
    PtyDataCallback callback;
    PtyExitCallback exit_callback;
    void* thread;
    void* exit_thread;
    
    // Synchronization
    void* mutex;        // pthread_mutex_t*
    int exit_code;
    int has_exited;
    int read_finished;
    int exit_fd;        // Pipe file descriptor to read exit code (Linux Double-Fork)
} PtyContext;

// Initialize the PTY system (sets up signal handlers)
void pty_init();

// Spawn a new process with PTY
// Returns a pointer to PtyContext on success, NULL on failure
// If envp is NULL, uses the current process environment
// If cwd is NULL, uses the current working directory
// mode specifies the terminal mode (canonical, cbreak, or raw)
PtyContext* pty_spawn(const char* command, char* const argv[], char* const envp[], const char* cwd, int mode, PtyDataCallback callback, PtyExitCallback exit_callback);

// Write data to the PTY
int pty_write(PtyContext* ctx, const uint8_t* data, int length);

// Resize the PTY window
int pty_resize(PtyContext* ctx, int rows, int cols);

// Send a signal to the PTY process
// Returns 0 on success, -1 on error
int pty_kill(PtyContext* ctx, int signal);

// Send a signal to only the foreground process group of the PTY.
// Uses tcgetpgrp() to target the correct job without affecting the shell.
// Returns 0 on success, -1 on error.
int pty_signal_foreground(PtyContext* ctx, int signal);

// Set the terminal mode
// Returns 0 on success, -1 on error
int pty_set_mode(PtyContext* ctx, int mode);

// Get the current terminal mode
// Returns the mode value (0, 1, or 2) on success, -1 on error
int pty_get_mode(PtyContext* ctx);

// Close and cleanup the PTY
void pty_close(PtyContext* ctx);

// Memory management functions for Dart
void* pty_malloc(size_t size);
void pty_free(void* ptr);

#endif // PTY_BRIDGE_H