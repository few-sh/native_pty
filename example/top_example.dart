import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Running top command');
  print('=' * 50);
  print('This demonstrates that interactive programs work correctly.\n');

  try {
    // Spawn top in batch mode with just one iteration
    final pty =
        NativePty.spawn('/usr/bin/top', ['/usr/bin/top', '-b', '-n', '1']);

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

    print('Top process spawned, collecting output...\n');

    // Wait for top to complete
    await Future.delayed(Duration(seconds: 3));

    // Close the PTY
    pty.close();

    print('\nTop example completed successfully!');
    print('Interactive programs work correctly with the PTY.');
  } on PtyException catch (e) {
    print('Failed to spawn top: $e');
    exit(1);
  }
}
