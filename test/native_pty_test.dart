import 'package:native_pty/native_pty.dart';
import 'package:test/test.dart';
import 'dart:io';
import 'dart:typed_data';

void main() {
  group('NativePty', () {
    test('spawn returns a NativePty instance', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'hello']);
      expect(pty, isNotNull);

      // Wait a bit for output
      await Future.delayed(Duration(milliseconds: 500));

      pty.close();
    });

    test('receives output from spawned process', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test_output']);

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Wait for output
      await Future.delayed(Duration(seconds: 1));

      pty.close();

      expect(outputBuffer.toString(), contains('test_output'));
    });

    test('can write to PTY', () async {
      final pty = NativePty.spawn('/bin/cat', ['/bin/cat']);

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(milliseconds: 200));

      // Write to the PTY
      final written = pty.write('hello\n');
      expect(written, greaterThan(0));

      await Future.delayed(Duration(milliseconds: 500));

      pty.close();

      expect(outputBuffer.toString(), contains('hello'));
    });

    test('can resize window', () async {
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

      await Future.delayed(Duration(milliseconds: 200));

      // Resize window - should not throw
      pty.resize(50, 120);

      pty.close();
    });

    test('throws StateError when writing to closed PTY', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test']);

      await Future.delayed(Duration(milliseconds: 500));
      pty.close();

      expect(() => pty.write('test'), throwsStateError);
    });

    test('throws StateError when resizing closed PTY', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test']);

      await Future.delayed(Duration(milliseconds: 500));
      pty.close();

      expect(() => pty.resize(24, 80), throwsStateError);
    });

    test('throws PtyException when spawning invalid command', () {
      expect(
        () => NativePty.spawn('/nonexistent/command', ['/nonexistent/command']),
        throwsA(isA<PtyException>()),
      );
    });

    test('handles high-output without memory issues', () async {
      // Spawn a command that produces a lot of output
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'yes "Hello World" | head -n 10000',
      ]);

      var totalBytes = 0;
      var chunkCount = 0;

      pty.stream.listen((data) {
        totalBytes += data.length;
        chunkCount++;
      });

      // Wait for the command to complete
      await Future.delayed(Duration(seconds: 5));

      pty.close();

      // Verify we received data
      expect(totalBytes, greaterThan(100000)); // Should be ~120KB
      expect(chunkCount, greaterThan(0));
    });

    test('handles UTF-8 characters correctly', () async {
      final outputBuffer = StringBuffer();

      // Test with multi-byte UTF-8 characters
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'echo "Hello 世界 🌍 测试 🚀"',
      ]);

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('世界'));
      expect(output, contains('🌍'));
      expect(output, contains('测试'));
      expect(output, contains('🚀'));
    });

    test('handles UTF-8 characters split across buffer boundaries', () async {
      final outputBuffer = StringBuffer();

      // Use C helper program to create a scenario where UTF-8 character is split
      // Helper writes 4090 bytes then a 4-byte emoji, then completion message
      final helperPath = 'bin/utf8_boundary_test_helper';
      final pty = NativePty.spawn(helperPath, [helperPath]);

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

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
      final outputBuffer = StringBuffer();

      // Spawn bash with custom environment variables
      final customEnv = {
        'TEST_VAR_1': 'value1',
        'TEST_VAR_2': 'value2',
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      };

      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        r'echo "TEST_VAR_1=$TEST_VAR_1" && echo "TEST_VAR_2=$TEST_VAR_2"',
      ], environment: customEnv);

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('TEST_VAR_1=value1'));
      expect(output, contains('TEST_VAR_2=value2'));
    });

    test('reports exit code for successful process', () async {
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'exit 0']);

      pty.stream.listen((data) {
        // Consume output
      });

      final exitCode = await pty.exitCode;
      expect(exitCode, equals(0));

      pty.close();
    });

    test(
      'correctly kills a process spawned via shell write (interactive mode)',
      () async {
        // Spawn interactive shell (like LocalShellBackend)
        final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

        // Script that spawns child processes (sleep in a loop)
        const script =
            'for i in {1..6}; do echo "\$((\$i * 20)) minutes passed"; if [ \$i -lt 6 ]; then sleep 1200; fi; done; echo "2 hours complete"';

        // Write command to the shell like LocalShellBackend does
        pty.write('$script\n');

        final outputBuffer = StringBuffer();
        pty.stream.listen((data) {
          outputBuffer.write(data);
        });

        // Wait for the script to start and print something
        await Future.delayed(Duration(seconds: 1));

        // Kill the PTY process (the interactive shell)
        // Send Ctrl-C to interrupt the loop (via kill SIGINT which maps to \x03 in canonical mode)
        pty.kill(ProcessSignal.sigint.signalNumber);

        // Wait a bit for the interrupt to handle
        await Future.delayed(Duration(milliseconds: 100));

        // Send exit command because Ctrl-C might have flushed the previous input
        pty.write('exit\n');

        // Wait for exit
        final exitCode = await pty.exitCode;

        // We expect the script to have started but not finished
        expect(outputBuffer.toString(), contains('20 minutes passed'));
        // "40 minutes passed" is not in the script source, so it won't be in the echo.
        // It would only appear if the loop continued to the second iteration.
        expect(outputBuffer.toString(), isNot(contains('40 minutes passed')));

        // The shell itself should have been killed
        // Since we "exit" gracefully after Ctrl-C, exit code might be 0 or 1 or 130
        // We just care that it exits.
        expect(exitCode, isNotNull);

        pty.close();
      },
    );

    test('reports exit code for failed process', () async {
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'exit 42']);

      pty.stream.listen((data) {
        // Consume output
      });

      final exitCode = await pty.exitCode;
      expect(exitCode, equals(42));

      pty.close();
    });

    test('exitCode is awaitable', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test']);

      pty.stream.listen((data) {
        // Consume output
      });

      // The exitCode future should complete
      final exitCode = await pty.exitCode.timeout(Duration(seconds: 2));
      expect(exitCode, equals(0));

      pty.close();
    });

    test('correctly kills a process with SIGQUIT (Ctrl-\)', () async {
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

      // Sleep in foreground
      pty.write('sleep 100\n');

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Wait for sleep to start
      await Future.delayed(Duration(seconds: 1));

      // Send SIGQUIT
      pty.kill(ProcessSignal.sigquit.signalNumber);

      // Wait a bit
      await Future.delayed(Duration(milliseconds: 100));

      // If sleep aborted, we should be back at prompt (or receive quit message)
      // Usually bash prints "Quit: 3" or similar
      pty.write('echo "ready"\n');

      // Wait for response
      await Future.delayed(Duration(milliseconds: 500));

      // Verify we are back alive and received the output of the echo command
      expect(outputBuffer.toString(), contains('ready'));

      pty.close();
    });

    test('correctly suspends a process with SIGTSTP (Ctrl-Z)', () async {
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

      // Sleep in foreground
      pty.write('sleep 100\n');

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Wait for sleep to start
      await Future.delayed(Duration(seconds: 1));

      // Send SIGTSTP
      pty.kill(ProcessSignal.sigtstp.signalNumber);

      // Wait a bit
      await Future.delayed(Duration(milliseconds: 500));

      // Verify sleep was stopped (bash usually says "Stopped")
      expect(outputBuffer.toString(), contains('Stopped'));

      // Clean up (kill the stopped job to avoid zombies/hanging shells)
      pty.write('kill %1\n');
      await Future.delayed(Duration(milliseconds: 100));

      pty.close();
    });

    test('can send SIGTERM signal', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'sleep 100',
      ]);

      pty.stream.listen((data) {
        // Consume output
      });

      await Future.delayed(Duration(milliseconds: 200));

      // Send SIGTERM - should not throw
      pty.kill(ProcessSignal.sigterm.signalNumber);

      final exitCode = await pty.exitCode;
      // Process killed by SIGTERM should have exit code 128 + 15 = 143
      expect(exitCode, equals(143));

      pty.close();
    });

    test('can send SIGKILL signal', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'sleep 100',
      ]);

      pty.stream.listen((data) {
        // Consume output
      });

      await Future.delayed(Duration(milliseconds: 500));

      // Send SIGKILL - should not throw
      pty.kill(ProcessSignal.sigkill.signalNumber);

      final exitCode = await pty.exitCode.timeout(Duration(seconds: 3));
      // Process killed by SIGKILL should have exit code 128 + 9 = 137
      expect(exitCode, equals(137));

      pty.close();
    });

    test(
      'kills signal-ignoring process and all descendant processes',
      () async {
        // Get the absolute path to the test script
        final scriptPath =
            '${Directory.current.path}/test/scripts/signal_ignoring_process.sh';

        // Verify the script exists
        if (!File(scriptPath).existsSync()) {
          fail('Test script not found at: $scriptPath');
        }

        // Spawn the signal-ignoring process via bash
        final pty = NativePty.spawn('/bin/bash', ['/bin/bash', scriptPath]);

        final outputBuffer = StringBuffer();
        pty.stream.listen((data) {
          outputBuffer.write(data);
        });

        // Wait for process to start and print a few iterations
        await Future.delayed(Duration(milliseconds: 800));

        // Verify the process is running
        expect(
          outputBuffer.toString(),
          contains('Signal-ignoring process started'),
        );
        expect(outputBuffer.toString(), contains('Iteration'));

        // Try to kill with SIGINT - process should ignore it
        pty.kill(ProcessSignal.sigint.signalNumber);
        await Future.delayed(Duration(milliseconds: 100));

        // Process should still be running and ignoring the signal
        expect(
          outputBuffer.toString(),
          contains('Received SIGINT, ignoring it'),
        );

        // Try SIGTERM - process should also ignore it
        pty.kill(ProcessSignal.sigterm.signalNumber);
        await Future.delayed(Duration(milliseconds: 100));

        expect(
          outputBuffer.toString(),
          contains('Received SIGTERM, ignoring it'),
        );

        // Finally send SIGKILL which cannot be ignored
        pty.kill(ProcessSignal.sigkill.signalNumber);

        // Wait for process to be killed
        final exitCode = await pty.exitCode.timeout(Duration(seconds: 5));

        // Process killed by SIGKILL should have exit code 128 + 9 = 137
        expect(exitCode, equals(137));

        pty.close();

        // Verify no orphaned processes remain
        // Check for any remaining bash processes running our script
        final checkResult = await Process.run('ps', ['aux']);

        final output = checkResult.stdout.toString();
        final scriptProcesses = output
            .split('\n')
            .where((line) => line.contains('signal_ignoring_process.sh'))
            .where((line) => !line.contains('grep'))
            .toList();

        expect(
          scriptProcesses.isEmpty,
          isTrue,
          reason:
              'No signal_ignoring_process.sh processes should be running after SIGKILL, found: ${scriptProcesses.length}',
        );

        // Also check for orphaned sleep processes that might have been spawned by the script
        // We look specifically for sleep 0.5 processes that are children of bash running our script
        final sleepProcesses = output
            .split('\n')
            .where((line) => line.contains('sleep 0.5'))
            .where((line) => !line.contains('grep'))
            .where((line) {
              // Try to filter out sleep processes from other tests
              // The signal_ignoring_process.sh script name should appear in the process tree
              return line.contains('bash') ||
                  output
                      .split('\n')
                      .any(
                        (l) =>
                            l.contains('signal_ignoring_process.sh') &&
                            line.split(RegExp(r'\s+'))[1] ==
                                l.split(RegExp(r'\s+'))[1],
                      );
            })
            .toList();

        // More lenient check - allow a brief window for cleanup
        if (sleepProcesses.isNotEmpty) {
          await Future.delayed(Duration(milliseconds: 500));
          final recheckResult = await Process.run('ps', ['aux']);
          final recheckOutput = recheckResult.stdout.toString();
          final remainingSleep = recheckOutput
              .split('\n')
              .where((line) => line.contains('sleep 0.5'))
              .where((line) => !line.contains('grep'))
              .toList();

          expect(
            remainingSleep.isEmpty,
            isTrue,
            reason:
                'No orphaned sleep processes should remain after SIGKILL and grace period, found: ${remainingSleep.length}',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('kill uses default SIGTERM when no signal specified', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'sleep 100',
      ]);

      pty.stream.listen((data) {
        // Consume output
      });

      await Future.delayed(Duration(milliseconds: 500));

      // Send default signal (SIGTERM) - should not throw
      pty.kill();

      final exitCode = await pty.exitCode.timeout(Duration(seconds: 3));
      // Process killed by SIGTERM should have exit code 128 + 15 = 143
      expect(exitCode, equals(143));

      pty.close();
    });

    test('avoids race condition where exitCode completes before data', () async {
      // Run multiple times to ensure stability
      for (int i = 0; i < 20; i++) {
        final pty = NativePty.spawn('/bin/echo', [
          '/bin/echo',
          'race_check_$i',
        ]);

        final output = StringBuffer();
        pty.stream.listen((data) {
          output.write(data);
        });

        // Await exit code - this should only complete AFTER data has been fully read
        await pty.exitCode;

        // Verify we captured the output
        expect(output.toString(), contains('race_check_$i'));

        pty.close();
      }
    });

    test('throws StateError when killing closed PTY', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test']);

      await Future.delayed(Duration(milliseconds: 500));
      pty.close();

      expect(() => pty.kill(), throwsStateError);
    });

    test('can set custom working directory', () async {
      final outputBuffer = StringBuffer();

      // Spawn bash with custom working directory
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'pwd',
      ], workingDirectory: '/tmp');

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('/tmp'));
    });

    test('uses current directory when workingDirectory is null', () async {
      final outputBuffer = StringBuffer();

      // Get current directory
      final currentDir = Directory.current.path;

      // Spawn bash without custom working directory
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'pwd']);

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains(currentDir));
    });

    test('can create files in custom working directory', () async {
      final outputBuffer = StringBuffer();

      final testFile =
          'native_pty_test_${DateTime.now().millisecondsSinceEpoch}.txt';

      // Spawn bash with custom working directory and create a file
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'echo "test" > $testFile && pwd && ls $testFile && rm $testFile',
      ], workingDirectory: '/tmp');

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      final output = outputBuffer.toString();
      expect(output, contains('/tmp'));
      expect(output, contains(testFile));
    });

    test('can spawn with canonical mode (default)', () async {
      final outputBuffer = StringBuffer();

      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'echo "canonical"',
      ], mode: TerminalMode.canonical);

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      expect(outputBuffer.toString(), contains('canonical'));
    });

    test('can spawn with cbreak mode', () async {
      final outputBuffer = StringBuffer();

      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'echo "cbreak"',
      ], mode: TerminalMode.cbreak);

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      expect(outputBuffer.toString(), contains('cbreak'));
    });

    test('can spawn with raw mode', () async {
      final outputBuffer = StringBuffer();

      final pty = NativePty.spawn('/bin/cat', [
        '/bin/cat',
      ], mode: TerminalMode.raw);

      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      await Future.delayed(Duration(milliseconds: 500));

      // Write some data in raw mode
      pty.write('raw mode test\n');

      await Future.delayed(Duration(milliseconds: 500));

      pty.close();

      expect(outputBuffer.toString(), contains('raw mode test'));
    });

    test('can get terminal mode', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
      ], mode: TerminalMode.cbreak);

      await Future.delayed(Duration(milliseconds: 200));

      final mode = pty.getMode();
      expect(mode, equals(TerminalMode.cbreak));

      pty.close();
    });

    test('can set terminal mode', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
      ], mode: TerminalMode.canonical);

      await Future.delayed(Duration(milliseconds: 200));

      expect(pty.getMode(), equals(TerminalMode.canonical));

      // Switch to raw mode - should not throw
      pty.setMode(TerminalMode.raw);
      expect(pty.getMode(), equals(TerminalMode.raw));

      // Switch to cbreak mode
      pty.setMode(TerminalMode.cbreak);
      expect(pty.getMode(), equals(TerminalMode.cbreak));

      pty.close();
    });

    test('terminal mode defaults to canonical', () async {
      // Spawn without specifying mode - should default to canonical
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash']);

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

    test('supports raw data output when autoDecodeUtf8 is false', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'echo "hello"',
      ], autoDecodeUtf8: false);

      final rawDataOptions = <int>[];
      final utf8DataOptions = <String>[];

      // Listen to both streams.
      // In autoDecodeUtf8: false mode, only the raw data stream should receive events.
      pty.data.listen((data) {
        rawDataOptions.addAll(data);
      });

      pty.stream.listen((data) {
        utf8DataOptions.add(data);
      });

      await pty.exitCode;

      pty.close();

      // Check raw data
      final rawString = String.fromCharCodes(rawDataOptions);
      expect(rawString, contains('hello'));

      // Check utf8 data is empty
      expect(utf8DataOptions, isEmpty);
    });

    test(
      'signalForeground interrupts foreground job but keeps shell alive',
      () async {
        // Spawn an interactive shell
        final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

        final outputBuffer = StringBuffer();
        pty.stream.listen((data) {
          outputBuffer.write(data);
        });

        // Wait for shell to start
        await Future.delayed(Duration(milliseconds: 500));

        // Run a long-running foreground command
        pty.write('sleep 300\n');
        await Future.delayed(Duration(milliseconds: 500));

        // Signal SIGINT to the foreground process group only
        pty.signalForeground(ProcessSignal.sigint.signalNumber);

        // Wait for the interrupt to take effect
        await Future.delayed(Duration(milliseconds: 500));

        // Shell should still be alive — verify by running another command
        pty.write('echo "shell_still_alive"\n');
        await Future.delayed(Duration(milliseconds: 500));

        expect(outputBuffer.toString(), contains('shell_still_alive'));

        pty.close();
      },
    );

    test('signalForeground works in raw mode', () async {
      // Spawn a shell in canonical mode, then switch it to raw mode
      // (bash -i sets its own terminal modes on startup; we need the shell
      // running first, then switch to raw before starting the foreground job)
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

      final outputBuffer = StringBuffer();
      pty.stream.listen((data) {
        outputBuffer.write(data);
      });

      // Wait for shell to start
      await Future.delayed(Duration(milliseconds: 500));

      // Switch terminal to raw mode from the Dart side
      pty.setMode(TerminalMode.raw);

      // Run a long-running foreground command
      pty.write('sleep 300\n');
      await Future.delayed(Duration(milliseconds: 500));

      // In raw mode, ISIG is off so writing \x03 alone would do nothing.
      // signalForeground uses kill() to deliver the signal directly.
      pty.signalForeground(ProcessSignal.sigint.signalNumber);

      // Wait for the interrupt to take effect
      await Future.delayed(Duration(milliseconds: 500));

      // Switch back to canonical so we get normal echo
      pty.setMode(TerminalMode.canonical);

      // Shell should still be alive — verify by running another command
      pty.write('echo "raw_mode_alive"\n');
      await Future.delayed(Duration(milliseconds: 500));

      expect(outputBuffer.toString(), contains('raw_mode_alive'));

      pty.close();
    });
  });
}
