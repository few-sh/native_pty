// Helper program for testing UTF-8 boundary handling
// Writes data designed to potentially split multi-byte UTF-8 characters across buffer boundaries

#include <stdio.h>
#include <unistd.h>

int main() {
    // Write 4090 'A' characters to approach 4096 buffer boundary
    for (int i = 0; i < 4090; i++) {
        putchar('A');
    }
    fflush(stdout);
    
    // Small delay to ensure separate write
    usleep(100000); // 0.1 seconds
    
    // Write a 4-byte UTF-8 emoji: 🚀 (F0 9F 9A 80)
    printf("🚀");
    fflush(stdout);
    
    // Small delay
    usleep(100000);
    
    // Write completion message
    printf(" Test Complete\n");
    fflush(stdout);
    
    return 0;
}
