import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Sending Signals');
  print('=' * 50);

  // Test 1: Send SIGTERM to a running process
  print('\nTest 1: Send SIGTERM to a long-running process');
  final pty1 = NativePty.spawn('/bin/bash',
      ['/bin/bash', '-c', 'while true; do echo "Running..."; sleep 1; done']);
  pty1.stream.listen((data) => stdout.write(data));

  // Let it run for a bit
  await Future.delayed(Duration(seconds: 2));

  // Send SIGTERM
  print('Sending SIGTERM...');
  pty1.kill(ProcessSignal.sigterm.signalNumber);

  final exitCode1 = await pty1.exitCode;
  print('Exit code: $exitCode1 (128 + ${exitCode1 - 128} = SIGTERM)');
  pty1.close();

  // Test 2: Send SIGINT (Ctrl+C)
  print('\nTest 2: Send SIGINT to a process');
  final pty2 = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);
  pty2.stream.listen((data) => stdout.write(data));

  await Future.delayed(Duration(milliseconds: 500));

  print('Sending SIGINT (Ctrl+C)...');
  pty2.kill(ProcessSignal.sigint.signalNumber);

  final exitCode2 = await pty2.exitCode;
  print('Exit code: $exitCode2 (128 + ${exitCode2 - 128} = SIGINT)');
  pty2.close();

  // Test 3: Send SIGKILL to a process
  print('\nTest 3: Send SIGKILL to a process');
  final pty3 = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);
  pty3.stream.listen((data) => stdout.write(data));

  await Future.delayed(Duration(milliseconds: 500));

  print('Sending SIGKILL...');
  pty3.kill(ProcessSignal.sigkill.signalNumber);

  final exitCode3 = await pty3.exitCode;
  print('Exit code: $exitCode3 (128 + ${exitCode3 - 128} = SIGKILL)');
  pty3.close();

  // Test 4: Default signal (SIGTERM)
  print('\nTest 4: Send default signal (SIGTERM)');
  final pty4 = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);
  pty4.stream.listen((data) => stdout.write(data));

  await Future.delayed(Duration(milliseconds: 500));

  print('Sending default signal (SIGTERM)...');
  pty4.kill(); // No signal parameter = default SIGTERM

  final exitCode4 = await pty4.exitCode;
  print('Exit code: $exitCode4 (128 + ${exitCode4 - 128} = SIGTERM)');
  pty4.close();

  print('\nAll tests completed!');
}
