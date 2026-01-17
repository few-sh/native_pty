import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Exit Code');
  print('=' * 50);

  // Test 1: Command that exits with code 0
  print('\nTest 1: Running command that exits with code 0');
  final pty1 = NativePty();
  pty1.stream.listen((data) => stdout.write(data));
  
  pty1.spawn('/bin/bash', ['/bin/bash', '-c', 'echo "Success"; exit 0']);
  final exitCode1 = await pty1.exitCode;
  print('Exit code: $exitCode1');
  pty1.close();

  // Test 2: Command that exits with non-zero code
  print('\nTest 2: Running command that exits with code 42');
  final pty2 = NativePty();
  pty2.stream.listen((data) => stdout.write(data));
  
  pty2.spawn('/bin/bash', ['/bin/bash', '-c', 'echo "Failure"; exit 42']);
  final exitCode2 = await pty2.exitCode;
  print('Exit code: $exitCode2');
  pty2.close();

  // Test 3: Command that completes normally
  print('\nTest 3: Running ls command');
  final pty3 = NativePty();
  pty3.stream.listen((data) => stdout.write(data));
  
  pty3.spawn('/bin/ls', ['/bin/ls', '-la', '/tmp']);
  final exitCode3 = await pty3.exitCode;
  print('\nExit code: $exitCode3');
  pty3.close();

  print('\nAll tests completed!');
}
