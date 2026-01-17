import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Running bash shell');
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

  // Spawn bash shell
  final success = pty.spawn('/bin/bash', ['/bin/bash', '-i']);
  if (!success) {
    print('Failed to spawn bash');
    exit(1);
  }

  print('Bash shell spawned, sending commands...\n');

  // Wait for shell to start
  await Future.delayed(Duration(milliseconds: 500));

  // Send some commands
  pty.write('echo "Hello from NativePty!"\n');
  await Future.delayed(Duration(milliseconds: 500));

  pty.write('ls -la /tmp | head -n 10\n');
  await Future.delayed(Duration(milliseconds: 500));

  pty.write('echo "Current directory: \$PWD"\n');
  await Future.delayed(Duration(milliseconds: 500));

  pty.write('exit\n');
  await Future.delayed(Duration(seconds: 1));

  // Close the PTY
  pty.close();

  print('\nBash example completed!');
}
