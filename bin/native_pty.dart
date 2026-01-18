import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main(List<String> arguments) async {
  print('NativePty Demo Application');
  print('=' * 50);

  if (arguments.isEmpty) {
    print('Usage: dart run native_pty <command> [args...]');
    print('\nExample:');
    print('  dart run native_pty /bin/ls -la');
    print('  dart run native_pty /bin/bash -i');
    exit(1);
  }

  final command = arguments[0];
  final args = arguments;

  print('Spawning: $command ${args.skip(1).join(" ")}');
  print('=' * 50);
  print('');

  final pty = NativePty();

  // Listen to the output stream
  pty.stream.listen(
    (data) {
      stdout.write(data);
    },
    onDone: () {
      print('\n--- Process terminated ---');
    },
    onError: (error) {
      stderr.writeln('Error: $error');
    },
  );

  // Spawn the command
  final success = pty.spawn(command, args);
  if (!success) {
    print('Failed to spawn process: $command');
    exit(1);
  }

  // Wait for process to complete
  await Future.delayed(Duration(seconds: 3));

  // Close the PTY
  pty.close();
}

