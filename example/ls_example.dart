import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Running ls command');
  print('=' * 50);

  final pty = NativePty();

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

  // Spawn ls command
  final success = pty.spawn('/bin/ls', ['/bin/ls', '-la']);
  if (!success) {
    print('Failed to spawn process');
    exit(1);
  }

  print('Process spawned successfully, waiting for output...\n');

  // Wait a bit for output
  await Future.delayed(Duration(seconds: 2));

  // Close the PTY
  pty.close();

  print('\nExample completed!');
}
