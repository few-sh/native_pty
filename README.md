# NativePty

A native pseudo-terminal (PTY) library for Dart using FFI.

## Features

- Spawn processes with a PTY using thread-safe `posix_spawn` (not `forkpty`)
- Read process output through a Dart Stream
- Write input to the process
- Resize the PTY window dynamically
- Automatic memory management and process cleanup
- Background I/O thread for non-blocking reads

## Architecture

The library consists of three layers:

1. **C Bridge Library** (`src/pty_bridge.c`): Manages low-level PTY lifecycle, spawning, and background I/O threads
2. **Dart FFI Bindings** (`lib/native_pty.dart`): Maps native functions and structs to Dart
3. **Dart High-Level API** (`NativePty` class): Provides a Stream interface and handles memory safety

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  native_pty:
    git:
      url: https://github.com/few-sh/native_pty.git
```

## Building

Before using the library, you need to build the native C library:

```bash
make
```

This will create `lib/linux/libpty_bridge.so` on Linux or `lib/macos/libpty_bridge.dylib` on macOS.

### Custom Library Path

By default, the library looks for the native library in the platform-specific directory. You can override this by setting the `NATIVE_PTY_LIBRARY_PATH` environment variable:

```bash
export NATIVE_PTY_LIBRARY_PATH=/custom/path/to/libpty_bridge.so
dart run your_app.dart
```

## Usage

### Basic Example - Running a Command

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  final pty = NativePty();

  // Listen to output
  pty.stream.listen((data) => stdout.write(data));

  // Spawn a process
  pty.spawn('/bin/ls', ['/bin/ls', '-la']);

  await Future.delayed(Duration(seconds: 1));
  pty.close();
}
```

### Interactive Shell Example

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  final pty = NativePty();

  pty.stream.listen((data) => stdout.write(data));

  // Spawn bash
  pty.spawn('/bin/bash', ['/bin/bash', '-i']);

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
final pty = NativePty();
pty.spawn('/bin/bash', ['/bin/bash', '-i']);

// Resize to 100 columns x 30 rows
pty.resize(30, 100);
```

### Custom Environment Variables

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  final pty = NativePty();

  pty.stream.listen((data) => stdout.write(data));

  // Spawn bash with custom environment variables
  final customEnv = {
    'MY_VAR': 'my_value',
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
  };

  pty.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'echo "MY_VAR=$MY_VAR"'],
    environment: customEnv,
  );

  await Future.delayed(Duration(seconds: 1));
  pty.close();
}
```

### Getting Process Exit Code

```dart
import 'package:native_pty/native_pty.dart';

void main() async {
  final pty = NativePty();

  pty.stream.listen((data) => print(data));

  pty.spawn('/bin/bash', ['/bin/bash', '-c', 'exit 42']);

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
  final pty = NativePty();

  pty.stream.listen((data) => stdout.write(data));

  // Spawn process with custom working directory
  pty.spawn(
    '/bin/bash',
    ['/bin/bash', '-c', 'pwd && ls -la'],
    workingDirectory: '/tmp',
  );

  await Future.delayed(Duration(seconds: 1));
  pty.close();
}
```

### Sending Signals to Processes

```dart
import 'dart:io';
import 'package:native_pty/native_pty.dart';

void main() async {
  final pty = NativePty();

  pty.stream.listen((data) => print(data));

  pty.spawn('/bin/bash', ['/bin/bash', '-c', 'sleep 100']);

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

#### Constructor
- `NativePty()` - Creates a new PTY instance

#### Methods
- `bool spawn(String command, List<String> args, {Map<String, String>? environment, String? workingDirectory})` - Spawns a process with the PTY
  - `command`: Full path to the executable
  - `args`: List of arguments (including argv[0])
  - `environment`: Optional map of environment variables (if null, inherits current process environment)
  - `workingDirectory`: Optional working directory for the process (if null, uses current directory)
  - Returns: `true` on success, `false` on failure

- `int write(String data)` - Writes data to the PTY
  - `data`: String to write
  - Returns: Number of bytes written, or -1 on error

- `int resize(int rows, int cols)` - Resizes the PTY window
  - `rows`: Number of rows (height)
  - `cols`: Number of columns (width)
  - Returns: 0 on success, -1 on error

- `int kill([int? signal])` - Sends a signal to the PTY process
  - `signal`: Signal number to send (defaults to SIGTERM if not specified)
  - Common signals: `ProcessSignal.sigterm.signalNumber` (15), `ProcessSignal.sigkill.signalNumber` (9), `ProcessSignal.sigint.signalNumber` (2)
  - Returns: 0 on success, -1 on error

- `void close()` - Closes the PTY and terminates the process

#### Properties
- `Stream<String> stream` - Stream of UTF-8 decoded output from the PTY
- `Future<int> exitCode` - Future that completes with the process exit code
  - Exit code is 0-255 if the process exited normally
  - Exit code is 128 + signal number if killed by a signal
  - Exit code is -1 if the status could not be determined

## Implementation Details

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

See the `example/` directory for more examples:

- `ls_example.dart` - Basic command execution
- `bash_example.dart` - Interactive shell with commands
- `resize_example.dart` - Window resizing demonstration
- `memory_test.dart` - Memory management under high load

## Testing

Run the tests:

```bash
dart test
```

## Platform Support

- ✅ Linux
- ✅ macOS (untested but should work)
- ❌ Windows (not supported - uses POSIX APIs)

## License

See LICENSE file for details.

