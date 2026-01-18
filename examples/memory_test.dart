import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Memory management test');
  print('=' * 50);
  print('Running a command that produces high output...\n');

  int totalBytes = 0;
  int chunkCount = 0;

  try {
    // Spawn a command that produces a lot of output
    // Using `yes` command limited by `head` to produce controlled output
    final pty = NativePty.spawn(
        '/bin/bash', ['/bin/bash', '-c', 'yes "Hello World" | head -n 10000']);

    // Listen to the output stream and count bytes
    pty.stream.listen(
      (data) {
        totalBytes += data.length;
        chunkCount++;
        // Don't print all data to avoid flooding the output
      },
      onDone: () {
        print('\n--- PTY stream closed ---');
        print('Total bytes received: $totalBytes');
        print('Total chunks received: $chunkCount');
      },
      onError: (error) {
        print('Error: $error');
      },
    );

    print('Process spawned, generating output...');

    // Wait for the command to complete
    await Future.delayed(Duration(seconds: 5));

    // Close the PTY
    pty.close();

    print('\nMemory test completed successfully!');
    print(
        'If you see this message without crashes, memory management is working.');
  } on PtyException catch (e) {
    print('Failed to spawn process: $e');
    exit(1);
  }
}
