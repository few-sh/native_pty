import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  print('=== Terminal Mode Example ===\n');

  // Example 1: Canonical mode (default) - line buffering
  print('1. Canonical Mode (line buffering, echoing, signals):');
  final pty1 = NativePty();
  pty1.stream.listen((data) => stdout.write(data));
  
  pty1.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'read -p "Enter text (canonical): " input && echo "You entered: \$input"'],
    mode: TerminalMode.canonical,
  );
  
  await Future.delayed(Duration(seconds: 2));
  pty1.close();
  print('');

  // Example 2: Cbreak mode - character-at-a-time
  print('2. Cbreak Mode (immediate input, echoing, signals):');
  final pty2 = NativePty();
  pty2.stream.listen((data) => stdout.write(data));
  
  pty2.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'echo "Press any key..."; read -n 1 key && echo "\nYou pressed a key!"'],
    mode: TerminalMode.cbreak,
  );
  
  await Future.delayed(Duration(seconds: 2));
  pty2.close();
  print('');

  // Example 3: Raw mode - for full-screen applications
  print('3. Raw Mode (no echoing, no signals, no processing):');
  final pty3 = NativePty();
  
  pty3.stream.listen((data) {
    stdout.write(data);
  });
  
  pty3.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'cat'],  // cat in raw mode
    mode: TerminalMode.raw,
  );
  
  await Future.delayed(Duration(milliseconds: 500));
  
  // In raw mode, characters are not echoed and not processed
  pty3.write('Hello in raw mode\n');
  
  await Future.delayed(Duration(milliseconds: 500));
  pty3.close();
  print('');

  // Example 4: Switching modes dynamically
  print('4. Dynamic Mode Switching:');
  final pty4 = NativePty();
  
  pty4.stream.listen((data) => stdout.write(data));
  
  // Start in canonical mode
  pty4.spawn(
    '/bin/bash',
    ['/bin/bash'],
    mode: TerminalMode.canonical,
  );
  
  await Future.delayed(Duration(milliseconds: 500));
  
  print('Current mode: ${pty4.getMode()}');
  
  // Switch to raw mode
  pty4.setMode(TerminalMode.raw);
  print('Switched to raw mode: ${pty4.getMode()}');
  
  await Future.delayed(Duration(milliseconds: 500));
  
  // Switch to cbreak mode
  pty4.setMode(TerminalMode.cbreak);
  print('Switched to cbreak mode: ${pty4.getMode()}');
  
  await Future.delayed(Duration(milliseconds: 500));
  
  // Switch back to canonical mode
  pty4.setMode(TerminalMode.canonical);
  print('Switched back to canonical mode: ${pty4.getMode()}');
  
  await Future.delayed(Duration(milliseconds: 500));
  pty4.close();
  print('');

  // Example 5: Raw mode for vim-like behavior
  print('5. Raw Mode for Full-Screen Applications (like vim):');
  final pty5 = NativePty();
  
  int lineCount = 0;
  pty5.stream.listen((data) {
    stdout.write(data);
    lineCount += '\n'.allMatches(data).length;
  });
  
  // Spawn cat in raw mode (simulating vim's raw terminal usage)
  pty5.spawn(
    '/bin/cat',
    ['/bin/cat'],
    mode: TerminalMode.raw,
  );
  
  await Future.delayed(Duration(milliseconds: 200));
  
  // In raw mode, we can send escape sequences for cursor control, etc.
  pty5.write('\x1b[2J\x1b[H');  // Clear screen and move cursor to home
  pty5.write('This is raw mode - suitable for vim/emacs\r\n');
  pty5.write('Press Ctrl+C here would send raw bytes, not signal\r\n');
  pty5.write('Escape sequences work: \x1b[1;31mRed text\x1b[0m\r\n');
  
  await Future.delayed(Duration(milliseconds: 500));
  pty5.close();
  
  print('\n\n=== Example Complete ===');
}
