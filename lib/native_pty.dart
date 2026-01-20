import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// Specify the asset ID that the hook/build.dart will produce
@ffi.DefaultAsset('native_pty.dart')
/// Terminal mode for PTY.
///
/// Controls how input and output are processed by the terminal.
enum TerminalMode {
  /// Default: Line buffering, character echoing, and signal processing.
  ///
  /// In this mode:
  /// - Input is line-buffered (read after Enter is pressed)
  /// - Characters are echoed to the terminal
  /// - Special characters like Ctrl+C generate signals (SIGINT)
  /// - Suitable for interactive shells and line-oriented programs
  canonical(0),

  /// No line buffering (immediate keys), but still handles signals like Ctrl+C.
  ///
  /// In this mode:
  /// - Input is available immediately (character-at-a-time)
  /// - Characters are echoed to the terminal
  /// - Special characters like Ctrl+C still generate signals
  /// - Suitable for programs that need immediate input but still want signal handling
  cbreak(1),

  /// Direct byte access: No echoing, no signals, no processing. Used by Vim/SSH.
  ///
  /// In this mode:
  /// - Input is available immediately (character-at-a-time)
  /// - No character echoing
  /// - No signal generation (Ctrl+C is passed as raw byte)
  /// - All special key processing is disabled
  /// - Suitable for full-screen applications like vim, emacs, less, top
  raw(2);

  /// The numeric value of this terminal mode.
  final int value;

  const TerminalMode(this.value);

  /// Creates a TerminalMode from its numeric value.
  static TerminalMode fromValue(int value) {
    switch (value) {
      case 0:
        return TerminalMode.canonical;
      case 1:
        return TerminalMode.cbreak;
      case 2:
        return TerminalMode.raw;
      default:
        throw ArgumentError('Invalid terminal mode value: $value');
    }
  }
}

// Native types
final class PtyContext extends ffi.Opaque {}

// Callback signature for data received from PTY
typedef PtyDataCallbackNative =
    ffi.Void Function(ffi.Pointer<ffi.Uint8> data, ffi.Int32 length);
typedef PtyDataCallback =
    void Function(ffi.Pointer<ffi.Uint8> data, int length);

// Callback signature for process exit notification
typedef PtyExitCallbackNative = ffi.Void Function(ffi.Int32 exitCode);
typedef PtyExitCallback = void Function(int exitCode);

// Native function signatures using @Native annotation
// These will be automatically linked by the native assets framework

@ffi.Native<ffi.Void Function()>(symbol: 'pty_init')
external void _ptyInit();

@ffi.Native<
  ffi.Pointer<PtyContext> Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Pointer<Utf8>>,
    ffi.Pointer<ffi.Pointer<Utf8>>,
    ffi.Pointer<Utf8>,
    ffi.Int32,
    ffi.Pointer<ffi.NativeFunction<PtyDataCallbackNative>>,
    ffi.Pointer<ffi.NativeFunction<PtyExitCallbackNative>>,
  )
>(symbol: 'pty_spawn')
external ffi.Pointer<PtyContext> _ptySpawn(
  ffi.Pointer<Utf8> command,
  ffi.Pointer<ffi.Pointer<Utf8>> argv,
  ffi.Pointer<ffi.Pointer<Utf8>> envp,
  ffi.Pointer<Utf8> cwd,
  int mode,
  ffi.Pointer<ffi.NativeFunction<PtyDataCallbackNative>> callback,
  ffi.Pointer<ffi.NativeFunction<PtyExitCallbackNative>> exitCallback,
);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<PtyContext>, ffi.Pointer<ffi.Uint8>, ffi.Int32)
>(symbol: 'pty_write')
external int _ptyWrite(
  ffi.Pointer<PtyContext> ctx,
  ffi.Pointer<ffi.Uint8> data,
  int length,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<PtyContext>, ffi.Int32, ffi.Int32)>(
  symbol: 'pty_resize',
)
external int _ptyResize(ffi.Pointer<PtyContext> ctx, int rows, int cols);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<PtyContext>, ffi.Int32)>(
  symbol: 'pty_kill',
)
external int _ptyKill(ffi.Pointer<PtyContext> ctx, int signal);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<PtyContext>, ffi.Int32)>(
  symbol: 'pty_set_mode',
)
external int _ptySetMode(ffi.Pointer<PtyContext> ctx, int mode);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<PtyContext>)>(symbol: 'pty_get_mode')
external int _ptyGetMode(ffi.Pointer<PtyContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<PtyContext>)>(symbol: 'pty_close')
external void _ptyClose(ffi.Pointer<PtyContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(symbol: 'pty_free')
external void _ptyFree(ffi.Pointer<ffi.Void> ptr);

/// Exception thrown when PTY operations fail.
class PtyException implements Exception {
  /// The error message describing what went wrong.
  final String message;

  /// Creates a new PtyException with the given [message].
  PtyException(this.message);

  @override
  String toString() => 'PtyException: $message';
}

/// A native pseudo-terminal (PTY) interface for Dart.
///
/// This class provides a high-level API for spawning processes with a PTY
/// and communicating with them through a Stream interface.
///
/// Use the static [spawn] method to create a new NativePty instance.
class NativePty {
  late final ffi.Pointer<PtyContext> _context;
  late final ffi.NativeCallable<PtyDataCallbackNative> _nativeCallback;
  late final ffi.NativeCallable<PtyExitCallbackNative> _nativeExitCallback;
  final StreamController<String> _controller = StreamController<String>();
  final StreamController<Uint8List> _dataController =
      StreamController<Uint8List>();
  late final ByteConversionSink _utf8Sink;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  bool _closed = false;

  /// Private constructor. Use [NativePty.spawn] to create instances.
  NativePty._();

  /// Initializes the callbacks and UTF-8 decoder.
  void _init() {
    // Initialize the PTY system
    _ptyInit();

    // Set up chunked UTF-8 decoder that maintains state between chunks
    // This handles multi-byte UTF-8 characters split across buffer boundaries
    final decoder = const Utf8Decoder(allowMalformed: true);
    _utf8Sink = decoder.startChunkedConversion(_StreamStringSink(_controller));

    // Set up the native callback
    _nativeCallback = ffi.NativeCallable<PtyDataCallbackNative>.listener(
      _onData,
    );

    // Set up the exit callback
    _nativeExitCallback = ffi.NativeCallable<PtyExitCallbackNative>.listener(
      _onExit,
    );
  }

  /// Callback for data received from the PTY.
  void _onData(ffi.Pointer<ffi.Uint8> data, int length) {
    try {
      // Convert native memory to Dart bytes
      final bytes = data.asTypedList(length);
      // Use chunked UTF-8 decoder to handle multi-byte characters split across buffers
      // The decoder maintains state and will buffer incomplete sequences
      if (!_closed) {
        _dataController.add(Uint8List.fromList(bytes));
        _utf8Sink.add(bytes);
      }
    } finally {
      // CRITICAL: Free the C memory now that Dart has copied it
      _ptyFree(data.cast<ffi.Void>());
    }
  }

  /// Callback for process exit notification.
  void _onExit(int exitCode) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(exitCode);
    }
  }

  /// Spawns a new process with a PTY and returns a [NativePty] instance.
  ///
  /// [command] is the path to the executable to run.
  /// [args] is the list of arguments to pass to the command (including argv[0]).
  /// [environment] is an optional map of environment variables to set for the process.
  /// If null, the current process environment is used.
  /// [workingDirectory] is an optional working directory for the process.
  /// If null, the current working directory is used.
  /// [mode] is the terminal mode to use. Defaults to [TerminalMode.canonical].
  ///
  /// Throws [PtyException] if the spawn fails.
  static NativePty spawn(
    String command,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
    TerminalMode mode = TerminalMode.canonical,
  }) {
    final pty = NativePty._();
    pty._init();

    // Allocate memory for command
    final commandPtr = command.toNativeUtf8(allocator: calloc);

    // Allocate memory for argv array (null-terminated)
    final argvPtr = calloc<ffi.Pointer<Utf8>>(args.length + 1);
    for (var i = 0; i < args.length; i++) {
      argvPtr[i] = args[i].toNativeUtf8(allocator: calloc);
    }
    argvPtr[args.length] = ffi.nullptr;

    // Allocate memory for environment array (null-terminated) if provided
    ffi.Pointer<ffi.Pointer<Utf8>> envpPtr = ffi.nullptr;
    List<String>? envStrings;

    if (environment != null) {
      // Convert map to KEY=VALUE strings
      envStrings = environment.entries
          .map((e) => '${e.key}=${e.value}')
          .toList();

      envpPtr = calloc<ffi.Pointer<Utf8>>(envStrings.length + 1);
      for (var i = 0; i < envStrings.length; i++) {
        envpPtr[i] = envStrings[i].toNativeUtf8(allocator: calloc);
      }
      envpPtr[envStrings.length] = ffi.nullptr;
    }

    // Allocate memory for working directory if provided
    ffi.Pointer<Utf8> cwdPtr = ffi.nullptr;
    if (workingDirectory != null) {
      cwdPtr = workingDirectory.toNativeUtf8(allocator: calloc);
    }

    try {
      final context = _ptySpawn(
        commandPtr,
        argvPtr,
        envpPtr,
        cwdPtr,
        mode.value,
        pty._nativeCallback.nativeFunction,
        pty._nativeExitCallback.nativeFunction,
      );

      if (context == ffi.nullptr) {
        pty._nativeCallback.close();
        pty._nativeExitCallback.close();
        pty._controller.close();
        throw PtyException('Failed to spawn PTY process for command: $command');
      }

      pty._context = context;
      return pty;
    } finally {
      // Clean up allocated memory
      calloc.free(commandPtr);
      for (var i = 0; i < args.length; i++) {
        calloc.free(argvPtr[i]);
      }
      calloc.free(argvPtr);

      // Clean up environment memory if allocated
      if (envpPtr != ffi.nullptr && envStrings != null) {
        for (var i = 0; i < envStrings.length; i++) {
          calloc.free(envpPtr[i]);
        }
        calloc.free(envpPtr);
      }

      // Clean up working directory memory if allocated
      if (cwdPtr != ffi.nullptr) {
        calloc.free(cwdPtr);
      }
    }
  }

  /// Writes data to the PTY.
  ///
  /// [data] is the string to write to the PTY.
  ///
  /// Returns the number of bytes written.
  /// Throws [PtyException] on error.
  int write(String data) {
    if (_closed) {
      throw StateError('PTY is closed');
    }

    final bytes = utf8.encode(data);
    return writeBytes(Uint8List.fromList(bytes));
  }

  /// Writes raw bytes to the PTY.
  ///
  /// [data] is the bytes to write to the PTY.
  ///
  /// Returns the number of bytes written.
  /// Throws [PtyException] on error.
  int writeBytes(Uint8List data) {
    if (_closed) {
      throw StateError('PTY is closed');
    }

    final length = data.length;

    // Allocate native memory for the data
    final dataPtr = calloc<ffi.Uint8>(length);
    try {
      // Efficiently copy bytes using asTypedList
      final nativeBytes = dataPtr.asTypedList(length);
      nativeBytes.setAll(0, data);

      final result = _ptyWrite(_context, dataPtr, length);
      if (result < 0) {
        throw PtyException('Failed to write to PTY');
      }
      return result;
    } finally {
      calloc.free(dataPtr);
    }
  }

  /// Resizes the PTY window.
  ///
  /// [rows] is the number of rows (height).
  /// [cols] is the number of columns (width).
  ///
  /// Throws [PtyException] on error.
  void resize(int rows, int cols) {
    if (_closed) {
      throw StateError('PTY is closed');
    }

    final result = _ptyResize(_context, rows, cols);
    if (result < 0) {
      throw PtyException('Failed to resize PTY to ${rows}x$cols');
    }
  }

  /// Sends a signal to the PTY process.
  ///
  /// [signal] is the signal number to send (e.g., ProcessSignal.sigterm.signalNumber).
  ///
  /// Common signals:
  /// - ProcessSignal.sigterm.signalNumber (15): Graceful termination
  /// - ProcessSignal.sigkill.signalNumber (9): Force kill
  /// - ProcessSignal.sigint.signalNumber (2): Interrupt (Ctrl+C)
  /// - ProcessSignal.sighup.signalNumber (1): Hangup
  ///
  /// Throws [PtyException] on error.
  void kill([int? signal]) {
    if (_closed) {
      throw StateError('PTY is closed');
    }

    // Default to SIGTERM if no signal specified
    final sig = signal ?? ProcessSignal.sigterm.signalNumber;
    final result = _ptyKill(_context, sig);
    if (result < 0) {
      throw PtyException('Failed to send signal $sig to PTY process');
    }
  }

  /// Sets the terminal mode for the PTY.
  ///
  /// [mode] is the terminal mode to set.
  ///
  /// Terminal modes:
  /// - [TerminalMode.canonical]: Line buffering, echoing, and signal processing (default)
  /// - [TerminalMode.cbreak]: Character-at-a-time input with signal processing
  /// - [TerminalMode.raw]: Raw mode with no processing (for vim, less, etc.)
  ///
  /// Throws [PtyException] on error.
  void setMode(TerminalMode mode) {
    if (_closed) {
      throw StateError('PTY is closed');
    }

    final result = _ptySetMode(_context, mode.value);
    if (result < 0) {
      throw PtyException('Failed to set terminal mode to ${mode.name}');
    }
  }

  /// Gets the current terminal mode of the PTY.
  ///
  /// Returns the current [TerminalMode].
  /// Throws [PtyException] on error.
  TerminalMode getMode() {
    if (_closed) {
      throw StateError('PTY is closed');
    }

    final modeValue = _ptyGetMode(_context);
    if (modeValue < 0) {
      throw PtyException('Failed to get terminal mode');
    }
    return TerminalMode.fromValue(modeValue);
  }

  /// Stream of data received from the PTY.
  ///
  /// Data is provided as UTF-8 decoded strings.
  Stream<String> get stream => _controller.stream;

  /// Stream of raw data received from the PTY.
  Stream<Uint8List> get data => _dataController.stream;

  /// Future that completes with the exit code when the process terminates.
  ///
  /// The exit code is:
  /// - The process exit code (0-255) if the process exited normally
  /// - 128 + signal number if the process was killed by a signal
  /// - -1 if the exit status could not be determined
  Future<int> get exitCode => _exitCodeCompleter.future;

  /// Closes the PTY and cleans up resources.
  ///
  /// This will terminate the child process and close the PTY.
  void close() {
    if (_closed) {
      return;
    }

    _closed = true;

    _ptyClose(_context);

    // Close the UTF-8 sink to flush any pending bytes
    _utf8Sink.close();
    _controller.close();
    _dataController.close();
    _nativeCallback.close();
    _nativeExitCallback.close();
  }
}

/// Helper class to adapt StreamController to Sink interface for UTF-8 decoder
class _StreamStringSink implements Sink<String> {
  final StreamController<String> _controller;

  _StreamStringSink(this._controller);

  @override
  void add(String data) {
    _controller.add(data);
  }

  @override
  void close() {
    // Don't close the controller here, it's managed by NativePty
  }
}
