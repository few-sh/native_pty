import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Testing window resize');
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

  print('Bash shell spawned, testing window resize...\n');
  await Future.delayed(Duration(milliseconds: 500));

  // Show current size using tput
  pty.write(r'echo "Initial size: $(tput cols)x$(tput lines)"' '\n');
  await Future.delayed(Duration(milliseconds: 500));

  // Resize the window
  print('\nResizing window to 100x30...');
  final resizeResult = pty.resize(30, 100);
  if (resizeResult == 0) {
    print('Window resized successfully!');
  } else {
    print('Failed to resize window');
  }

  await Future.delayed(Duration(milliseconds: 200));

  // Check the new size
  pty.write(r'echo "After resize: $(tput cols)x$(tput lines)"' '\n');
  await Future.delayed(Duration(milliseconds: 500));

  // Resize again
  print('\nResizing window to 50x15...');
  pty.resize(15, 50);
  await Future.delayed(Duration(milliseconds: 200));

  pty.write(r'echo "After second resize: $(tput cols)x$(tput lines)"' '\n');
  await Future.delayed(Duration(milliseconds: 500));

  pty.write('exit\n');
  await Future.delayed(Duration(seconds: 1));

  // Close the PTY
  pty.close();

  print('\nResize example completed!');
}
