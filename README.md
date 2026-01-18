# NativePty

A native pseudo-terminal (PTY) library for Dart using FFI and Dart's Native Assets framework.

## Features

- Spawn processes with a PTY using thread-safe `posix_spawn` (not `forkpty`)
- Read process output through a Dart Stream
- Write input to the process
- Resize the PTY window dynamically
- Automatic memory management and process cleanup
- Background I/O thread for non-blocking reads
- Built with Dart's Native Assets framework for automatic native library building and bundling

## Architecture

The library consists of three layers:

1. **C Bridge Library** (`src/pty_bridge.c`): Manages low-level PTY lifecycle, spawning, and background I/O threads
2. **Dart FFI Bindings** (`lib/native_pty.dart`): Maps native functions and structs to Dart using `@Native` annotations
3. **Dart High-Level API** (`NativePty` class): Provides a Stream interface and handles memory safety
4. **Build Hook** (`hook/build.dart`): Automatically builds the native C library using Dart's native assets framework

## Requirements

- Dart SDK >= 3.10.4
- C compiler (gcc or clang)
- Linux or macOS (Windows is not supported)

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  native_pty:
    git:
      url: https://github.com/few-sh/native_pty.git
```

## Building

**No manual build step is required!** The native C library is automatically built and bundled when you run your Dart application, thanks to Dart's Native Assets framework.

When you run `dart run`, `dart test`, or build your application, the build hook (`hook/build.dart`) automatically:
1. Compiles `src/pty_bridge.c` to a shared library
2. Links it with the required system libraries (e.g., `-lutil`)
3. Bundles it with your application

### Manual Build (Optional)

If you need to build the native library manually (e.g., for development), you can still use the Makefile:

```bash
make
```

This will create:
- `lib/linux/libpty_bridge.so` on Linux or `lib/macos/libpty_bridge.dylib` on macOS
- `bin/utf8_boundary_test_helper` - A helper program for testing UTF-8 boundary handling

## Usage

### Basic Example - Running a Command

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  // Spawn a process - the native library is automatically loaded
  final pty = NativePty.spawn('/bin/ls', ['/bin/ls', '-la']);

  // Listen to output
  pty.stream.listen((data) => stdout.write(data));

  await Future.delayed(Duration(seconds: 1));
  pty.close();
}
```

### Interactive Shell Example

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  // Spawn bash
  final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

  pty.stream.listen((data) => stdout.write(data));

  await Future.delayed(Duration(milliseconds: 500));

  // Send commands
  pty.write('echo "Hello from NativePty!"\n');
  pty.write('ls -la\n');
  pty.write('exit\n');

  await Future.delayed(Duration(seconds: 2));
  pty.close();
}
```

### Window Resizing

```dart
final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-i']);

// Resize to 100 columns x 30 rows
pty.resize(30, 100);
```

### Custom Environment Variables

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  // Spawn bash with custom environment variables
  final customEnv = {
    'MY_VAR': 'my_value',
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
  };

  final pty = NativePty.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'echo "MY_VAR=$MY_VAR"'],
    environment: customEnv,
  );

  pty.stream.listen((data) => stdout.write(data));

  await Future.delayed(Duration(seconds: 1));
  pty.close();
}
```

### Getting Process Exit Code

```dart
import 'package:native_pty/native_pty.dart';

void main() async {
  final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'exit 42']);

  pty.stream.listen((data) => print(data));

  // Wait for the process to exit and get its exit code
  final exitCode = await pty.exitCode;
  print('Process exited with code: $exitCode');

  pty.close();
}
```

### Setting Working Directory

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  // Spawn process with custom working directory
  final pty = NativePty.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'pwd && ls -la'],
    workingDirectory: '/tmp',
  );

  pty.stream.listen((data) => stdout.write(data));

  await Future.delayed(Duration(seconds: 1));
  pty.close();
}
```

### Setting Terminal Mode

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  // Spawn with raw mode (for vim, less, etc.)
  final pty = NativePty.spawn(
    '/bin/bash',
    ['/bin/bash'],
    mode: TerminalMode.raw,  // canonical (default), cbreak, or raw
  );

  await Future.delayed(Duration(milliseconds: 500));

  // Change mode dynamically
  pty.setMode(TerminalMode.canonical);
  print('Current mode: ${pty.getMode()}');  // TerminalMode.canonical

  await Future.delayed(Duration(seconds: 1));
  pty.close();
}
```

Terminal modes:
- **`TerminalMode.canonical`** (default): Line buffering, character echoing, signal processing (Ctrl+C generates SIGINT)
- **`TerminalMode.cbreak`**: Character-at-a-time input, echoing, signal processing
- **`TerminalMode.raw`**: No buffering, no echoing, no signal processing - suitable for vim, emacs, less, top

### Sending Signals to Processes

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  final pty = NativePty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);

  pty.stream.listen((data) => print(data));

  await Future.delayed(Duration(seconds: 2));

  // Send SIGTERM to gracefully terminate the process
  pty.kill(ProcessSignal.sigterm.signalNumber);

  // Or use default SIGTERM
  // pty.kill();

  final exitCode = await pty.exitCode;
  print('Process exited with code: $exitCode');

  pty.close();
}
```

## API Reference

### `NativePty` Class

#### Static Factory Method
- `NativePty.spawn(String command, List<String> args, {Map<String, String>? environment, String? workingDirectory, TerminalMode mode})` - Creates and spawns a new PTY instance
  - `command`: Full path to the executable
  - `args`: List of arguments (including argv[0])
  - `environment`: Optional map of environment variables (if null, inherits current process environment)
  - `workingDirectory`: Optional working directory for the process (if null, uses current directory)
  - `mode`: Terminal mode (defaults to `TerminalMode.canonical`)
  - Returns: A new `NativePty` instance with the process running
  - Throws: `PtyException` if spawn fails

#### Methods
- `int write(String data)` - Writes data to the PTY
  - `data`: String to write
  - Returns: Number of bytes written
  - Throws: `PtyException` on error, `StateError` if PTY is closed

- `void resize(int rows, int cols)` - Resizes the PTY window
  - `rows`: Number of rows (height)
  - `cols`: Number of columns (width)
  - Throws: `PtyException` on error, `StateError` if PTY is closed

- `void kill([int? signal])` - Sends a signal to the PTY process
  - `signal`: Signal number to send (defaults to SIGTERM if not specified)
  - Common signals: `ProcessSignal.sigterm.signalNumber` (15), `ProcessSignal.sigkill.signalNumber` (9), `ProcessSignal.sigint.signalNumber` (2)
  - Throws: `PtyException` on error, `StateError` if PTY is closed

- `void setMode(TerminalMode mode)` - Sets the terminal mode
  - `mode`: Terminal mode to set (`canonical`, `cbreak`, or `raw`)
  - Throws: `PtyException` on error, `StateError` if PTY is closed

- `TerminalMode getMode()` - Gets the current terminal mode
  - Returns: Current `TerminalMode`
  - Throws: `PtyException` on error, `StateError` if PTY is closed

- `void close()` - Closes the PTY and terminates the process

#### Properties
- `Stream<String> stream` - Stream of UTF-8 decoded output from the PTY
- `Future<int> exitCode` - Future that completes with the process exit code
  - Exit code is 0-255 if the process exited normally
  - Exit code is 128 + signal number if killed by a signal
  - Exit code is -1 if the status could not be determined

### `TerminalMode` Enum

Defines the terminal input/output processing mode:

- `TerminalMode.canonical` (0): Line buffering, character echoing, signal processing (default)
- `TerminalMode.cbreak` (1): Character-at-a-time input, echoing, signal processing
- `TerminalMode.raw` (2): No processing, no echoing, no signals - for full-screen applications

## Implementation Details

### Native Assets Framework

This library uses Dart's Native Assets framework to automatically build and bundle the native C library:

- **Build Hook** (`hook/build.dart`): Automatically compiles the C code when you build or run the application
- **@DefaultAsset Annotation**: The Dart code uses `@DefaultAsset` and `@Native` annotations to automatically link to the compiled library
- **No Manual Library Loading**: The library no longer needs manual `DynamicLibrary.open()` calls - everything is handled by the Dart SDK

### Thread Safety

The library uses `posix_spawn` instead of `forkpty()` to avoid threading issues in multi-threaded environments. The background I/O thread reads from the PTY and sends data to Dart through a `NativeCallable.listener`.

### Memory Management

- Data read from the PTY is allocated in C using `malloc()`
- The Dart callback receives the pointer and copies the data
- The callback immediately calls `free()` to release the C memory
- The `NativePty` class automatically cleans up resources when closed

### Process Cleanup

- Signal handler set to `SIG_IGN` for `SIGCHLD` to prevent zombie processes
- When closing, the library sends `SIGTERM` followed by `SIGKILL` if needed

## Examples

See the `examples/` directory for more examples:

- `ls_example.dart` - Basic command execution
- `bash_example.dart` - Interactive shell with commands
- `resize_example.dart` - Window resizing demonstration
- `memory_test.dart` - Memory management under high load
- `env_example.dart` - Custom environment variables
- `cwd_example.dart` - Custom working directory
- `terminal_mode_example.dart` - Different terminal modes
- `kill_example.dart` - Sending signals to processes
- `exitcode_example.dart` - Getting process exit codes

To run an example:

```bash
cd examples
dart pub get
dart run ls_example.dart
```

## Testing

Run the tests:

```bash
dart test
```

All tests automatically build the native library before running.

## Platform Support

- ✅ Linux
- ✅ macOS (untested but should work)
- ❌ Windows (not supported - uses POSIX APIs)

## License

See LICENSE file for details.

