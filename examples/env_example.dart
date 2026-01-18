import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Environment Variables');
  print('=' * 50);

  final outputBuffer = StringBuffer();

  // Spawn bash with custom environment variables
  final customEnv = {
    'MY_CUSTOM_VAR': 'Hello from NativePty!',
    'ANOTHER_VAR': 'Testing 123',
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    'HOME': Platform.environment['HOME'] ?? '/home',
  };

  try {
    final pty = NativePty.spawn(
      '/bin/bash',
      [
        '/bin/bash',
        '-c',
        r'echo "MY_CUSTOM_VAR=$MY_CUSTOM_VAR" && echo "ANOTHER_VAR=$ANOTHER_VAR"'
      ],
      environment: customEnv,
    );

    // Listen to the output stream
    pty.stream.listen(
      (data) {
        outputBuffer.write(data);
        stdout.write(data);
      },
      onDone: () {
        print('\n--- PTY stream closed ---');
      },
      onError: (error) {
        print('Error: $error');
      },
    );

    print('Bash shell spawned with custom environment variables...\n');

    // Wait for output
    await Future.delayed(Duration(seconds: 2));

    // Close the PTY
    pty.close();

    // Verify we got the expected output
    final output = outputBuffer.toString();

    print('\n=== Verification ===');
    if (output.contains('MY_CUSTOM_VAR=Hello from NativePty!')) {
      print('✓ MY_CUSTOM_VAR set correctly');
    } else {
      print('✗ MY_CUSTOM_VAR not found or incorrect');
    }

    if (output.contains('ANOTHER_VAR=Testing 123')) {
      print('✓ ANOTHER_VAR set correctly');
    } else {
      print('✗ ANOTHER_VAR not found or incorrect');
    }

    print('\nEnvironment variable example completed!');
  } on PtyException catch (e) {
    print('Failed to spawn bash: $e');
    exit(1);
  }
}
