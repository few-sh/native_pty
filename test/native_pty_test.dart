import 'package:native_pty/native_pty.dart';
import 'package:test/test.dart';

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
  });
}
