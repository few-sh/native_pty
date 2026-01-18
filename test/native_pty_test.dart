import 'package:native_pty/native_pty.dart';
import 'package:test/test.dart';
import 'dart:io';

void main() {
  group('NativePty', () {
    test('can be instantiated', () {
      final pty = NativePty();
      expect(pty, isNotNull);
      pty.close();
    });

    test('can spawn a process', () async {
      final pty = NativePty();
      
      final success = pty.spawn('/bin/echo', ['/bin/echo', 'hello']);
      expect(success, isTrue);

      // Wait a bit for output
      await Future.delayed(Duration(milliseconds: 500));

      pty.close();
    });

    test('receives output from spawned process', () async {
      final pty = NativePty();
      
      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      final success = pty.spawn('/bin/echo', ['/bin/echo', 'test_output']);
      expect(success, isTrue);

      // Wait for output
      await Future.delayed(Duration(seconds: 1));

      pty.close();

      expect(outputBuffer.toString(), contains('test_output'));
    });

    test('can write to PTY', () async {
      final pty = NativePty();
      
      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      final success = pty.spawn('/bin/cat', ['/bin/cat']);
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 200));

      // Write to the PTY
      final written = pty.write('hello\n');
      expect(written, greaterThan(0));

      await Future.delayed(Duration(milliseconds: 500));

      pty.close();

      expect(outputBuffer.toString(), contains('hello'));
    });

    test('can resize window', () async {
      final pty = NativePty();
      
      final success = pty.spawn('/bin/bash', ['/bin/bash', '-i']);
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 200));

      // Resize window
      final result = pty.resize(50, 120);
      expect(result, equals(0));

      pty.close();
    });

    test('throws StateError when writing to non-spawned PTY', () {
      final pty = NativePty();
      
      expect(() => pty.write('test'), throwsStateError);
      
      pty.close();
    });

    test('throws StateError when resizing non-spawned PTY', () {
      final pty = NativePty();
      
      expect(() => pty.resize(24, 80), throwsStateError);
      
      pty.close();
    });

    test('throws StateError when spawning twice', () {
      final pty = NativePty();
      
      pty.spawn('/bin/echo', ['/bin/echo', 'test']);
      
      expect(
        () => pty.spawn('/bin/echo', ['/bin/echo', 'test2']),
        throwsStateError,
      );
      
      pty.close();
    });

    test('handles high-output without memory issues', () async {
      final pty = NativePty();

      var totalBytes = 0;
      var chunkCount = 0;

      pty.stream.listen((data) {
        totalBytes += data.length;
        chunkCount++;
      });

      // Spawn a command that produces a lot of output
      final success = pty.spawn(
          '/bin/bash', ['/bin/bash', '-c', 'yes "Hello World" | head -n 10000']);
      expect(success, isTrue);

      // Wait for the command to complete
      await Future.delayed(Duration(seconds: 5));

      pty.close();

      // Verify we received data
      expect(totalBytes, greaterThan(100000)); // Should be ~120KB
      expect(chunkCount, greaterThan(0));
    });

    test('handles UTF-8 characters correctly', () async {
      final pty = NativePty();

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Test with multi-byte UTF-8 characters
      final success = pty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'echo "Hello 世界 🌍 测试 🚀"'
      ]);
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('世界'));
      expect(output, contains('🌍'));
      expect(output, contains('测试'));
      expect(output, contains('🚀'));
    });

    test('handles UTF-8 characters split across buffer boundaries', () async {
      final pty = NativePty();

      var callbackCount = 0;
      final outputBuffer = StringBuffer();

      pty.stream.listen((data) {
        callbackCount++;
        outputBuffer.write(data);
      });

      // Use C helper program to create a scenario where UTF-8 character is split
      // Helper writes 4090 bytes then a 4-byte emoji, then completion message
      final helperPath = 'bin/utf8_boundary_test_helper';
      final success = pty.spawn(helperPath, [helperPath]);
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 2));

      pty.close();

      final output = outputBuffer.toString();
      // Verify the emoji was correctly decoded
      expect(output, contains('🚀'));
      expect(output, contains('Test Complete'));
      // Verify we got the expected number of A's
      expect('A'.allMatches(output).length, equals(4090));
    });

    test('can set custom environment variables', () async {
      final pty = NativePty();

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Spawn bash with custom environment variables
      final customEnv = {
        'TEST_VAR_1': 'value1',
        'TEST_VAR_2': 'value2',
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      };

      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash', '-c', r'echo "TEST_VAR_1=$TEST_VAR_1" && echo "TEST_VAR_2=$TEST_VAR_2"'],
        environment: customEnv,
      );
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('TEST_VAR_1=value1'));
      expect(output, contains('TEST_VAR_2=value2'));
    });

    test('reports exit code for successful process', () async {
      final pty = NativePty();

      pty.stream.listen((data) {
        // Consume output
      });

      final success = pty.spawn('/bin/bash', ['/bin/bash', '-c', 'exit 0']);
      expect(success, isTrue);

      final exitCode = await pty.exitCode;
      expect(exitCode, equals(0));

      pty.close();
    });

    test('reports exit code for failed process', () async {
      final pty = NativePty();

      pty.stream.listen((data) {
        // Consume output
      });

      final success = pty.spawn('/bin/bash', ['/bin/bash', '-c', 'exit 42']);
      expect(success, isTrue);

      final exitCode = await pty.exitCode;
      expect(exitCode, equals(42));

      pty.close();
    });

    test('exitCode is awaitable', () async {
      final pty = NativePty();

      pty.stream.listen((data) {
        // Consume output
      });

      final success = pty.spawn('/bin/echo', ['/bin/echo', 'test']);
      expect(success, isTrue);

      // The exitCode future should complete
      final exitCode = await pty.exitCode.timeout(Duration(seconds: 2));
      expect(exitCode, equals(0));

      pty.close();
    });

    test('can send SIGTERM signal', () async {
      final pty = NativePty();

      pty.stream.listen((data) {
        // Consume output
      });

      final success = pty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 200));

      // Send SIGTERM
      final result = pty.kill(ProcessSignal.sigterm.signalNumber);
      expect(result, equals(0));

      final exitCode = await pty.exitCode;
      // Process killed by SIGTERM should have exit code 128 + 15 = 143
      expect(exitCode, equals(143));

      pty.close();
    });

    test('can send SIGKILL signal', () async {
      final pty = NativePty();

      pty.stream.listen((data) {
        // Consume output
      });

      final success = pty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 500));

      // Send SIGKILL
      final result = pty.kill(ProcessSignal.sigkill.signalNumber);
      expect(result, equals(0));

      final exitCode = await pty.exitCode.timeout(Duration(seconds: 3));
      // Process killed by SIGKILL should have exit code 128 + 9 = 137
      expect(exitCode, equals(137));

      pty.close();
    });

    test('kill uses default SIGTERM when no signal specified', () async {
      final pty = NativePty();

      pty.stream.listen((data) {
        // Consume output
      });

      final success = pty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 500));

      // Send default signal (SIGTERM)
      final result = pty.kill();
      expect(result, equals(0));

      final exitCode = await pty.exitCode.timeout(Duration(seconds: 3));
      // Process killed by SIGTERM should have exit code 128 + 15 = 143
      expect(exitCode, equals(143));

      pty.close();
    });

    test('throws StateError when killing non-spawned PTY', () {
      final pty = NativePty();
      
      expect(() => pty.kill(), throwsStateError);
      
      pty.close();
    });

    test('can set custom working directory', () async {
      final pty = NativePty();

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Spawn bash with custom working directory
      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash', '-c', 'pwd'],
        workingDirectory: '/tmp',
      );
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('/tmp'));
    });

    test('uses current directory when workingDirectory is null', () async {
      final pty = NativePty();

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Get current directory
      final currentDir = Directory.current.path;

      // Spawn bash without custom working directory
      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash', '-c', 'pwd'],
      );
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains(currentDir));
    });

    test('can create files in custom working directory', () async {
      final pty = NativePty();

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      final testFile = 'native_pty_test_${DateTime.now().millisecondsSinceEpoch}.txt';

      // Spawn bash with custom working directory and create a file
      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash', '-c', 'echo "test" > $testFile && pwd && ls $testFile && rm $testFile'],
        workingDirectory: '/tmp',
      );
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('/tmp'));
      expect(output, contains(testFile));
    });

    test('can spawn with canonical mode (default)', () async {
      final pty = NativePty();
      
      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash', '-c', 'echo "canonical"'],
        mode: TerminalMode.canonical,
      );
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      expect(outputBuffer.toString(), contains('canonical'));
    });

    test('can spawn with cbreak mode', () async {
      final pty = NativePty();
      
      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash', '-c', 'echo "cbreak"'],
        mode: TerminalMode.cbreak,
      );
      expect(success, isTrue);

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      expect(outputBuffer.toString(), contains('cbreak'));
    });

    test('can spawn with raw mode', () async {
      final pty = NativePty();
      
      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      final success = pty.spawn(
        '/bin/cat',
        ['/bin/cat'],
        mode: TerminalMode.raw,
      );
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 500));

      // Write some data in raw mode
      pty.write('raw mode test\n');

      await Future.delayed(Duration(milliseconds: 500));

      pty.close();

      expect(outputBuffer.toString(), contains('raw mode test'));
    });

    test('can get terminal mode', () async {
      final pty = NativePty();

      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash'],
        mode: TerminalMode.cbreak,
      );
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 200));

      final mode = pty.getMode();
      expect(mode, equals(TerminalMode.cbreak));

      pty.close();
    });

    test('can set terminal mode', () async {
      final pty = NativePty();

      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash'],
        mode: TerminalMode.canonical,
      );
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 200));

      expect(pty.getMode(), equals(TerminalMode.canonical));

      // Switch to raw mode
      final result = pty.setMode(TerminalMode.raw);
      expect(result, equals(0));
      expect(pty.getMode(), equals(TerminalMode.raw));

      // Switch to cbreak mode
      pty.setMode(TerminalMode.cbreak);
      expect(pty.getMode(), equals(TerminalMode.cbreak));

      pty.close();
    });

    test('terminal mode defaults to canonical', () async {
      final pty = NativePty();

      // Spawn without specifying mode - should default to canonical
      final success = pty.spawn(
        '/bin/bash',
        ['/bin/bash'],
      );
      expect(success, isTrue);

      await Future.delayed(Duration(milliseconds: 200));

      final mode = pty.getMode();
      expect(mode, equals(TerminalMode.canonical));

      pty.close();
    });

    test('TerminalMode fromValue works correctly', () {
      expect(TerminalMode.fromValue(0), equals(TerminalMode.canonical));
      expect(TerminalMode.fromValue(1), equals(TerminalMode.cbreak));
      expect(TerminalMode.fromValue(2), equals(TerminalMode.raw));
      
      expect(() => TerminalMode.fromValue(3), throwsArgumentError);
      expect(() => TerminalMode.fromValue(-1), throwsArgumentError);
    });
  });
}

