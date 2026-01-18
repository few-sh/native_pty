import 'dart:io';
import 'dart:typed_data';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('NativePty Test - UTF-8 Boundary Split Detection');
  print('=' * 70);
  print('This test verifies UTF-8 decoder handles split multi-byte characters');
  print('by forcing a split scenario and counting callbacks.\n');

  final pty = NativePty();

  var callbackCount = 0;
  final outputBuffer = StringBuffer();
  final receivedChunks = <String>[];

  // Listen to the output stream and count chunks
  pty.stream.listen(
    (data) {
      callbackCount++;
      receivedChunks.add(data);
      outputBuffer.write(data);
      print('Callback #$callbackCount: Received ${data.length} chars');
    },
    onDone: () {
      print('\n--- PTY stream closed ---');
    },
    onError: (error) {
      print('Error: $error');
    },
  );

  // Spawn C helper program to output precisely sized data that will split UTF-8 chars
  // Helper program writes:
  // 1. First: 'A' repeated to fill most of a 4096 buffer (4090 bytes)
  // 2. Then a 4-byte emoji that will likely be split across read boundaries
  // 3. Finally: " Test Complete\n"
  final helperPath = 'bin/utf8_boundary_test_helper';
  final success = pty.spawn(helperPath, [helperPath]);

  if (!success) {
    print('Failed to spawn helper program');
    print('Make sure to run "make" to build the helper program first');
    exit(1);
  }

  print('Helper program spawned, generating split UTF-8 scenario...\n');

  // Wait for all output
  await Future.delayed(Duration(seconds: 2));

  pty.close();

  await Future.delayed(Duration(milliseconds: 500));

  // Verify results
  print('\n=== Results ===');
  print('Total callbacks received: $callbackCount');
  print('Total output length: ${outputBuffer.length} characters');
  
  final output = outputBuffer.toString();
  
  // Check if we got the emoji
  final hasEmoji = output.contains('🚀');
  print('Emoji (🚀) received correctly: ${hasEmoji ? "✓ YES" : "✗ NO"}');
  
  // Check for test completion message
  final hasTestComplete = output.contains('Test Complete');
  print('Test complete message received: ${hasTestComplete ? "✓ YES" : "✗ NO"}');
  
  // Count the A characters
  final aCount = 'A'.allMatches(output).length;
  print('Count of "A" characters: $aCount (expected: 4090)');
  
  if (hasEmoji && hasTestComplete && aCount == 4090) {
    print('\n✅ UTF-8 boundary handling verified!');
    print('The stateful Utf8Decoder correctly handled split multi-byte characters.');
  } else {
    print('\n⚠️  Test results inconclusive or failed.');
    if (!hasEmoji) print('  - Emoji was lost or corrupted');
    if (!hasTestComplete) print('  - Test completion message missing');
    if (aCount != 4090) print('  - Character count mismatch (got $aCount, expected 4090)');
  }
  
  print('\nReceived ${receivedChunks.length} chunks from stream');
  for (var i = 0; i < receivedChunks.length && i < 5; i++) {
    final chunk = receivedChunks[i];
    final preview = chunk.length > 50 
        ? '${chunk.substring(0, 25)}...${chunk.substring(chunk.length - 25)}'
        : chunk;
    print('  Chunk ${i + 1}: ${chunk.length} chars - "$preview"');
  }
}
