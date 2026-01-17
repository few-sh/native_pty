#ifndef PTY_BRIDGE_H
#define PTY_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// Callback signature for data received from PTY
typedef void (*PtyDataCallback)(uint8_t* data, int32_t length);

// Context structure for PTY management
typedef struct {
    int master_fd;
    int pid;
    int running;
    PtyDataCallback callback;
    void* thread;
} PtyContext;

// Initialize the PTY system (sets up signal handlers)
void pty_init();

// Spawn a new process with PTY
// Returns a pointer to PtyContext on success, NULL on failure
PtyContext* pty_spawn(const char* command, char* const argv[], PtyDataCallback callback);

// Write data to the PTY
int pty_write(PtyContext* ctx, const uint8_t* data, int length);

// Resize the PTY window
int pty_resize(PtyContext* ctx, int rows, int cols);

// Close and cleanup the PTY
void pty_close(PtyContext* ctx);

// Memory management functions for Dart
void* pty_malloc(size_t size);
void pty_free(void* ptr);

#endif // PTY_BRIDGE_H