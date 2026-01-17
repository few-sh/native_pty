import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Working Directory');
  print('=' * 50);

  // Test 1: Run pwd without specifying working directory
  print('\nTest 1: pwd without custom working directory');
  final pty1 = NativePty();
  pty1.stream.listen((data) => stdout.write(data));
  
  pty1.spawn('/bin/bash', ['/bin/bash', '-c', 'pwd']);
  await Future.delayed(Duration(seconds: 1));
  pty1.close();

  // Test 2: Run pwd with custom working directory
  print('\nTest 2: pwd with custom working directory /tmp');
  final pty2 = NativePty();
  pty2.stream.listen((data) => stdout.write(data));
  
  pty2.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'pwd'],
    workingDirectory: '/tmp',
  );
  await Future.delayed(Duration(seconds: 1));
  pty2.close();

  // Test 3: List files in custom working directory
  print('\nTest 3: List files in /etc directory');
  final pty3 = NativePty();
  pty3.stream.listen((data) => stdout.write(data));
  
  pty3.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'pwd && ls -la | head -10'],
    workingDirectory: '/etc',
  );
  await Future.delayed(Duration(seconds: 1));
  pty3.close();

  // Test 4: Create a file in custom directory
  print('\nTest 4: Create file in /tmp and verify');
  final pty4 = NativePty();
  pty4.stream.listen((data) => stdout.write(data));
  
  final testFile = 'native_pty_test_${DateTime.now().millisecondsSinceEpoch}.txt';
  pty4.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'pwd && echo "Test content" > $testFile && ls -la $testFile && rm $testFile'],
    workingDirectory: '/tmp',
  );
  await Future.delayed(Duration(seconds: 1));
  pty4.close();

  print('\nAll tests completed!');
}
