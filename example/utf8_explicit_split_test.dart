import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Test - Explicit UTF-8 Character Split Test');
  print('=' * 70);
  print('This test uses a C program to force a split in the middle of a');
  print('4-byte UTF-8 character (emoji) and verifies correct reassembly.\n');

  // First, create a C program that outputs specific bytes with delays
  final testProgram = '''
#include <stdio.h>
#include <unistd.h>

int main() {
    // The emoji 🚀 in UTF-8 is: F0 9F 9A 80 (4 bytes)
    // We'll write the first 2 bytes, flush, then the last 2 bytes
    
    // Write some initial data
    printf("START:");
    fflush(stdout);
    usleep(50000);  // 50ms delay
    
    // Write first 2 bytes of 🚀 (F0 9F)
    unsigned char bytes1[] = {0xF0, 0x9F};
    fwrite(bytes1, 1, 2, stdout);
    fflush(stdout);
    usleep(50000);  // 50ms delay to ensure separate read
    
    // Write last 2 bytes of 🚀 (9A 80)
    unsigned char bytes2[] = {0x9A, 0x80};
    fwrite(bytes2, 1, 2, stdout);
    fflush(stdout);
    usleep(50000);
    
    // Write some final data
    printf(":END\\n");
    fflush(stdout);
    
    return 0;
}
''';

  // Write the C program
  final tmpFile = File('/tmp/utf8_split_test.c');
  await tmpFile.writeAsString(testProgram);

  // Compile it
  print('Compiling test program...');
  final compileResult = await Process.run(
    'gcc',
    ['-o', '/tmp/utf8_split_test', '/tmp/utf8_split_test.c'],
  );

  if (compileResult.exitCode != 0) {
    print('Failed to compile test program:');
    print(compileResult.stderr);
    exit(1);
  }

  print('Test program compiled successfully.\n');

  var callbackCount = 0;
  final outputBuffer = StringBuffer();
  final receivedChunks = <String>[];

  try {
    // Spawn the test program
    final pty =
        NativePty.spawn('/tmp/utf8_split_test', ['/tmp/utf8_split_test']);

    // Listen to the output stream and count chunks
    pty.stream.listen(
      (data) {
        callbackCount++;
        receivedChunks.add(data);
        outputBuffer.write(data);

        // Show bytes for debugging
        final bytes = data.codeUnits;
        final bytesHex =
            bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        print(
            'Callback #$callbackCount: ${data.length} chars, bytes: $bytesHex');
        print('  Content: "${data.replaceAll('\n', '\\n')}"');
      },
      onDone: () {
        print('\n--- PTY stream closed ---');
      },
      onError: (error) {
        print('Error: $error');
      },
    );

    print('Test program spawned, forcing UTF-8 split...\n');

    // Wait for all output
    await Future.delayed(Duration(seconds: 2));

    pty.close();

    await Future.delayed(Duration(milliseconds: 500));

    // Verify results
    print('\n=== Test Results ===');
    print('Total callbacks received: $callbackCount');

    final output = outputBuffer.toString();
    print('Total output: "${output.replaceAll('\n', '\\n')}"');

    // Check if we got the complete sequence
    final hasStart = output.contains('START:');
    final hasEmoji = output.contains('🚀');
    final hasEnd = output.contains(':END');

    print('\nVerification:');
    print('  START marker: ${hasStart ? "✓" : "✗"}');
    print('  Emoji (🚀): ${hasEmoji ? "✓" : "✗"}');
    print('  END marker: ${hasEnd ? "✓" : "✗"}');

    // The expected behavior is that the stateful Utf8Decoder will:
    // 1. Receive first 2 bytes (F0 9F) - decoder waits for more bytes
    // 2. Receive next 2 bytes (9A 80) - decoder completes the character
    // Result: The emoji appears correctly in the output

    if (hasStart && hasEmoji && hasEnd) {
      print('\n✅ SUCCESS!');
      print(
          'The stateful Utf8Decoder correctly handled a 4-byte UTF-8 character');
      print('that was split across multiple read operations.');
      print('This confirms the fix prevents data loss at buffer boundaries.');
    } else {
      print('\n❌ FAILED!');
      if (!hasEmoji) {
        print(
            'The emoji was lost or corrupted - UTF-8 decoder may not be stateful!');
      }
    }
  } on PtyException catch (e) {
    print('Failed to spawn test program: $e');
    exit(1);
  }

  // Cleanup
  await tmpFile.delete();
  await File('/tmp/utf8_split_test').delete();
}
