import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Example - Testing UTF-8 character boundary handling');
  print('=' * 70);
  print('This test verifies that multi-byte UTF-8 characters are handled');
  print('correctly even when split across buffer boundaries.\n');

  final pty = NativePty();

  final outputBuffer = StringBuffer();

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

  // Spawn bash and output various UTF-8 characters including emojis
  final success = pty.spawn('/bin/bash', ['/bin/bash', '-i']);
  if (!success) {
    print('Failed to spawn bash');
    exit(1);
  }

  print('Bash shell spawned, testing UTF-8 characters...\n');

  await Future.delayed(Duration(milliseconds: 500));

  // Test various multi-byte UTF-8 characters
  // These include 2-byte, 3-byte, and 4-byte UTF-8 sequences
  pty.write('echo "Hello 世界 🌍 测试 🚀 émojis ñ"\n');
  await Future.delayed(Duration(milliseconds: 500));

  // Test a longer string with lots of multi-byte characters
  pty.write('echo "日本語 한국어 中文 العربية हिन्दी ภาษาไทย русский язык"\n');
  await Future.delayed(Duration(milliseconds: 500));

  // Test emojis and symbols
  pty.write('echo "😀 😃 😄 😁 🎉 🎊 🎈 ✨ 💖 💕 🌟 ⭐"\n');
  await Future.delayed(Duration(milliseconds: 500));

  pty.write('exit\n');
  await Future.delayed(Duration(seconds: 1));

  // Close the PTY
  pty.close();

  // Verify we got the expected characters
  final output = outputBuffer.toString();
  
  print('\n=== Verification ===');
  final testCases = [
    '世界',
    '🌍',
    '测试',
    '🚀',
    'émojis',
    'ñ',
    '日本語',
    '한국어',
    'العربية',
    'हिन्दी',
    '😀',
    '🎉',
    '✨',
    '💖',
  ];

  var allPassed = true;
  for (final testCase in testCases) {
    if (output.contains(testCase)) {
      print('✓ Found: $testCase');
    } else {
      print('✗ Missing: $testCase');
      allPassed = false;
    }
  }

  print('\n${allPassed ? "All UTF-8 characters handled correctly!" : "Some characters were lost!"}');
  print('\nUTF-8 boundary handling test completed!');
}
