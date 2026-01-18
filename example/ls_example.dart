import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Running ls command');
  print('=' * 50);

  try {
    final pty = NativePty.spawn('/bin/ls', ['/bin/ls', '-la']);

    // Listen to the output stream
    pty.stream.listen(
      (data) {
        stdout.write(data);
      },
      onDone: () {
        print('\n--- PTY stream closed ---');
      },
      onError: (error) {
        print('Error: $error');
      },
    );

    print('Process spawned successfully, waiting for output...\n');

    // Wait a bit for output
    await Future.delayed(Duration(seconds: 2));

    // Close the PTY
    pty.close();

    print('\nExample completed!');
  } on PtyException catch (e) {
    print('Failed to spawn process: $e');
    exit(1);
  }
}
