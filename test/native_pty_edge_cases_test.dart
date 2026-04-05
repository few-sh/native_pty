import 'package:native_pty/native_pty.dart';
import 'package:test/test.dart';
import 'dart:io';
import 'dart:async';

void main() {
  group('NativePty Edge Cases', () {
    test(
      'handles closing PTY while callback is actively processing data',
      () async {
        // Spawn a process that produces continuous output
        final pty = NativePty.spawn('/bin/bash', [
          '/bin/bash',
          '-c',
          'for i in {1..1000}; do echo "Line \$i"; done',
        ]);

        var callbackCount = 0;
        final subscription = pty.stream.listen((data) {
          callbackCount++;
          // Simulate some processing time
          if (callbackCount == 3) {
            // Close while we're in the middle of receiving data
            pty.close();
          }
        });

        // Wait for close to happen
        await Future.delayed(Duration(seconds: 1));

        // Should not crash or hang
        await subscription.cancel();
        expect(callbackCount, greaterThanOrEqualTo(3));
      },
    );

    test('handled interactive command execution followed by an exit', () async {
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

      final output = StringBuffer();
      final completer = Completer<void>();

      pty.stream.listen(
        (data) {
          output.write(data);
          if (output.toString().contains('dummy command')) {}
        },
        onDone: () {
          completer.complete();
        },
      );

      // Write a command that produces output
      final command = '''
echo "Running dummy command"
''';
      pty.write('$command\n');
      pty.write('exit\n');

      final exitCode = await pty.exitCode;

      // Wait for process to exit
      await completer.future;

      expect(exitCode, equals(0));
      expect(output.toString(), contains('Running dummy command'));

      pty.close();
    });

    test('handles rapid spawn and close cycles', () async {
      // Rapidly create and destroy PTY instances
      for (int i = 0; i < 50; i++) {
        final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test_$i']);

        // Listen to avoid stream backpressure
        final subscription = pty.stream.listen((_) {});

        // Close immediately, sometimes even before process completes
        if (i % 2 == 0) {
          // Immediate close
          pty.close();
        } else {
          // Slight delay
          await Future.delayed(Duration(milliseconds: 10));
          pty.close();
        }

        await subscription.cancel();
      }

      // If we get here without crashing or hanging, test passes
      expect(true, isTrue);
    });

    test('handles closing PTY exactly during process exit', () async {
      for (int i = 0; i < 20; i++) {
        // Spawn a short-lived process
        final pty = NativePty.spawn('/bin/bash', [
          '/bin/bash',
          '-c',
          'echo "quick"; exit 0',
        ]);

        var exitCodeCompleted = false;
        pty.stream.listen((_) {});

        // Race: try to close right when process exits
        unawaited(
          pty.exitCode.then((_) {
            exitCodeCompleted = true;
          }),
        );

        // Wait a bit then close
        await Future.delayed(Duration(milliseconds: 50));
        pty.close();

        // Wait to see if exitCode completed
        await Future.delayed(Duration(milliseconds: 100));

        // Test passes if we don't crash or hang
      }

      expect(true, isTrue);
    });

    test('handles multiple concurrent writes during close', () async {
      final pty = NativePty.spawn('/bin/cat', ['/bin/cat']);

      pty.stream.listen((_) {});

      await Future.delayed(Duration(milliseconds: 100));

      // Start multiple writes
      final writes = <Future<void>>[];
      for (int i = 0; i < 10; i++) {
        writes.add(
          Future(() {
            try {
              pty.write('data_$i\n');
            } catch (e) {
              // StateError is expected if close happens first
              expect(e, isA<StateError>());
            }
          }),
        );
      }

      // Close in the middle of writes
      await Future.delayed(Duration(milliseconds: 5));
      pty.close();

      // Wait for all writes to complete or fail
      await Future.wait(writes);

      // Test passes if we don't crash
      expect(true, isTrue);
    });

    test('handles very large single write', () async {
      // Use short lines to avoid hitting MAX_CANON input buffer limit.
      final pty = NativePty.spawn('/bin/cat', ['/bin/cat']);

      final outputBuffer = StringBuffer();
      final completer = Completer<void>();

      pty.stream.listen(
        (data) {
          outputBuffer.write(data);
        },
        onDone: () {
          completer.complete();
        },
      );

      // Create a very large write but with newlines every 80 chars
      // 'X' * 80 + '\n' = 81 chars.
      // 100000 / 81 = 1234 lines.
      final line = 'X' * 80 + '\n';
      final largeData = line * 1235; // ~100KB
      final bytesWritten = pty.write(largeData);

      // Should write all data now that we handle partial writes
      expect(bytesWritten, greaterThan(100000));

      // Close stdin to signal EOF to cat, which will cause it to exit
      pty.write('\x04'); // EOF (Ctrl+D)

      // Wait for the process to exit naturally
      final exitCode = await pty.exitCode;
      expect(exitCode, equals(0));

      // Wait for stream to close (all data delivered)
      await completer.future;

      // We should get ALL data back now that we avoid canonical limit and premature closing
      expect(outputBuffer.length, greaterThan(100000));
    });

    test('handles very large write with bundled EOF', () async {
      final pty = NativePty.spawn('/bin/cat', ['/bin/cat']);

      final outputBuffer = StringBuffer();
      final completer = Completer<void>();

      pty.stream.listen(
        (data) {
          outputBuffer.write(data);
        },
        onDone: () {
          completer.complete();
        },
      );

      // Create a very large write
      // Use lines to avoid MAX_CANON truncation
      final line = 'X' * 80 + '\n';
      final largeData = line * 1235; // ~100KB

      // Write data and EOF in one call
      final bytesWritten = pty.write('$largeData\x04');

      // Should write all data including EOF byte
      expect(bytesWritten, greaterThan(100000));

      // Wait for the process to exit naturally (cat sees EOF in stream)
      final exitCode = await pty.exitCode;
      expect(exitCode, equals(0));

      // Wait for stream to close (all data delivered)
      await completer.future;

      // We should see ALL data now.
      expect(outputBuffer.length, greaterThan(100000));
    });

    test('handles very large output with echo in raw mode', () async {
      final largeData = 'X' * 100000; // 100KB

      final pty = NativePty.spawn(
        '/bin/echo',
        ['/bin/echo', '-n', largeData], // -n to avoid adding newline
        mode: TerminalMode.raw,
      );

      final outputBuffer = StringBuffer();
      final completer = Completer<void>();

      pty.stream.listen(
        (data) {
          outputBuffer.write(data);
        },
        onDone: () {
          completer.complete();
        },
      );

      // Wait for the process to exit naturally (echo outputs and exits)
      final exitCode = await pty.exitCode;
      expect(exitCode, equals(0));

      // Wait for stream to close (all data delivered)
      await completer.future;

      // With echo, all data is from the argument, not stdin
      // In raw mode with immediate exit, we should get ALL data
      expect(outputBuffer.length, equals(100000));
    });

    test('handles closing PTY with unread buffered data', () async {
      // Spawn process that produces output
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'for i in {1..100}; do echo "Data \$i"; done',
      ]);

      // Don't listen to stream (data will buffer)
      await Future.delayed(Duration(milliseconds: 500));

      // Now close with buffered data still in stream
      pty.close();

      // Test passes if we don't crash or leak memory
      expect(true, isTrue);
    });

    test('handles process that exits immediately during spawn', () async {
      // Process that exits almost instantly
      for (int i = 0; i < 20; i++) {
        final pty = NativePty.spawn('/bin/true', ['/bin/true']);

        pty.stream.listen((_) {});

        final exitCode = await pty.exitCode.timeout(Duration(seconds: 2));
        expect(exitCode, equals(0));

        pty.close();
      }
    });

    test('handles process that exits with error immediately', () async {
      // Process that fails instantly
      for (int i = 0; i < 20; i++) {
        final pty = NativePty.spawn('/bin/false', ['/bin/false']);

        pty.stream.listen((_) {});

        final exitCode = await pty.exitCode.timeout(Duration(seconds: 2));
        expect(exitCode, equals(1));

        pty.close();
      }
    });

    test('handles rapid write then immediate close', () async {
      for (int i = 0; i < 30; i++) {
        final pty = NativePty.spawn('/bin/cat', ['/bin/cat']);

        pty.stream.listen((_) {});

        // Write immediately
        try {
          pty.write('test\n');
        } catch (_) {
          // Might fail if process not ready yet
        }

        // Close immediately after write
        pty.close();
      }

      // Test passes if no crashes
      expect(true, isTrue);
    });

    test('handles reading exitCode multiple times', () async {
      final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'exit 42']);

      pty.stream.listen((_) {});

      // Get exitCode multiple times
      final exitCode1 = await pty.exitCode;
      final exitCode2 = await pty.exitCode;
      final exitCode3 = await pty.exitCode;

      expect(exitCode1, equals(42));
      expect(exitCode2, equals(42));
      expect(exitCode3, equals(42));

      pty.close();
    });

    test(
      'handles process spawning child processes that outlive parent',
      () async {
        // Spawn a process that creates background jobs
        final pty = NativePty.spawn('/bin/bash', [
          '/bin/bash',
          '-c',
          // Background process that ignores HUP
          'nohup sleep 0.5 >/dev/null 2>&1 & echo "Parent done"',
        ]);

        final output = StringBuffer();
        pty.stream.listen((data) {
          output.write(data);
        });

        await Future.delayed(Duration(milliseconds: 300));

        expect(output.toString(), contains('Parent done'));

        pty.close();

        // Wait for background process to finish
        await Future.delayed(Duration(milliseconds: 500));

        // Test that we don't have zombie processes
        // (The cleanup should have worked)
        expect(true, isTrue);
      },
    );

    test('handles closing PTY from within stream callback', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'for i in {1..100}; do echo "Line \$i"; sleep 0.01; done',
      ]);

      var lineCount = 0;
      final completer = Completer<void>();

      pty.stream.listen((data) {
        if (data.contains('Line')) {
          lineCount++;
        }
        if (lineCount >= 5) {
          // Close PTY from within its own callback
          if (!completer.isCompleted) {
            completer.complete();
            pty.close();
          }
        }
      });

      await completer.future.timeout(
        Duration(seconds: 3),
        onTimeout: () {
          pty.close();
          throw TimeoutException('Test timed out');
        },
      );

      expect(lineCount, greaterThanOrEqualTo(5));
    });

    test('handles resize during active data transfer', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'for i in {1..1000}; do echo "Line \$i"; done',
      ]);

      pty.stream.listen((_) {});

      // Resize multiple times during data transfer
      for (int i = 0; i < 10; i++) {
        await Future.delayed(Duration(milliseconds: 50));
        try {
          pty.resize(24 + i, 80 + i);
        } catch (e) {
          // Might fail if PTY closed
          expect(e, anyOf(isA<StateError>(), isA<PtyException>()));
        }
      }

      pty.close();

      expect(true, isTrue);
    });

    test('handles sending signal during active write', () async {
      final pty = NativePty.spawn('/bin/cat', ['/bin/cat']);

      pty.stream.listen((_) {});

      await Future.delayed(Duration(milliseconds: 100));

      // Start writing
      final writeFuture = Future(() async {
        for (int i = 0; i < 100; i++) {
          try {
            pty.write('data_$i\n');
            await Future.delayed(Duration(milliseconds: 10));
          } catch (e) {
            // Expected if process killed
            break;
          }
        }
      });

      // Send signal while writing
      await Future.delayed(Duration(milliseconds: 200));
      try {
        pty.kill(ProcessSignal.sigterm.signalNumber);
      } catch (_) {
        // Might already be closed
      }

      await writeFuture;
      await Future.delayed(Duration(milliseconds: 100));

      pty.close();

      expect(true, isTrue);
    });

    test('handles spawning with empty environment', () async {
      // Test spawning with minimal environment
      final pty = NativePty.spawn(
        '/bin/bash',
        ['/bin/bash', '-c', 'echo \$PATH'],
        environment: {'PATH': '/bin:/usr/bin'},
      );

      final output = StringBuffer();
      pty.stream.listen((data) {
        output.write(data);
      });

      await Future.delayed(Duration(seconds: 1));

      pty.close();

      // Should have our PATH
      expect(output.toString(), contains('/bin'));
    });

    test('handles closing already closed PTY multiple times', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test']);

      pty.stream.listen((_) {});

      await Future.delayed(Duration(milliseconds: 500));

      // Close multiple times
      pty.close();
      pty.close();
      pty.close();

      // Should not crash
      expect(true, isTrue);
    });

    test('handles operations after process natural exit', () async {
      final pty = NativePty.spawn('/bin/echo', ['/bin/echo', 'test']);

      pty.stream.listen((_) {});

      // Wait for process to exit naturally
      final exitCode = await pty.exitCode;
      expect(exitCode, equals(0));

      // Give PTY time to process exit callback
      await Future.delayed(Duration(milliseconds: 100));

      // After process exits, operations should throw StateError
      expect(() => pty.write('test'), throwsStateError);
      expect(() => pty.resize(24, 80), throwsStateError);
      expect(() => pty.kill(), throwsStateError);

      pty.close();
    });

    test('handles process that produces output then hangs', () async {
      final pty = NativePty.spawn('/bin/bash', [
        '/bin/bash',
        '-c',
        'echo "Started"; sleep 100',
      ]);

      final output = StringBuffer();
      pty.stream.listen((data) {
        output.write(data);
      });

      await Future.delayed(Duration(milliseconds: 500));

      expect(output.toString(), contains('Started'));

      // Kill the hanging process
      pty.kill(ProcessSignal.sigkill.signalNumber);

      final exitCode = await pty.exitCode.timeout(Duration(seconds: 2));
      expect(exitCode, equals(137)); // SIGKILL = 128 + 9

      pty.close();
    });

    test('stress test: many concurrent PTY instances', () async {
      final ptys = <NativePty>[];
      final subscriptions = <StreamSubscription>[];

      // Create many PTY instances at once
      for (int i = 0; i < 20; i++) {
        final pty = NativePty.spawn('/bin/bash', [
          '/bin/bash',
          '-c',
          'echo "Instance $i"; sleep 0.5',
        ]);

        ptys.add(pty);
        subscriptions.add(pty.stream.listen((_) {}));
      }

      // Wait a bit
      await Future.delayed(Duration(seconds: 1));

      // Close all
      for (final pty in ptys) {
        pty.close();
      }

      for (final sub in subscriptions) {
        await sub.cancel();
      }

      // Test passes if no crashes or hangs
      expect(ptys.length, equals(20));
    });

    test('throws PtyException when workingDirectory does not exist', () {
      expect(
        () => NativePty.spawn('/bin/echo', [
          '/bin/echo',
          'hello',
        ], workingDirectory: '/nonexistent/directory'),
        throwsA(
          isA<PtyException>().having(
            (e) => e.message,
            'message',
            contains('No such file or directory'),
          ),
        ),
      );
    });
  });
}
