import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:convert';
import 'package:ffi/ffi.dart';

// Native types
final class PtyContext extends ffi.Opaque {}

// Callback signature for data received from PTY
typedef PtyDataCallbackNative = ffi.Void Function(
    ffi.Pointer<ffi.Uint8> data, ffi.Int32 length);
typedef PtyDataCallback = void Function(
    ffi.Pointer<ffi.Uint8> data, int length);

// Native function signatures
typedef PtyInitNative = ffi.Void Function();
typedef PtyInit = void Function();

typedef PtySpawnNative = ffi.Pointer<PtyContext> Function(
    ffi.Pointer<Utf8> command,
    ffi.Pointer<ffi.Pointer<Utf8>> argv,
    ffi.Pointer<ffi.Pointer<Utf8>> envp,
    ffi.Pointer<ffi.NativeFunction<PtyDataCallbackNative>> callback);
typedef PtySpawn = ffi.Pointer<PtyContext> Function(
    ffi.Pointer<Utf8> command,
    ffi.Pointer<ffi.Pointer<Utf8>> argv,
    ffi.Pointer<ffi.Pointer<Utf8>> envp,
    ffi.Pointer<ffi.NativeFunction<PtyDataCallbackNative>> callback);

typedef PtyWriteNative = ffi.Int32 Function(
    ffi.Pointer<PtyContext> ctx, ffi.Pointer<ffi.Uint8> data, ffi.Int32 length);
typedef PtyWrite = int Function(
    ffi.Pointer<PtyContext> ctx, ffi.Pointer<ffi.Uint8> data, int length);

typedef PtyResizeNative = ffi.Int32 Function(
    ffi.Pointer<PtyContext> ctx, ffi.Int32 rows, ffi.Int32 cols);
typedef PtyResize = int Function(
    ffi.Pointer<PtyContext> ctx, int rows, int cols);

typedef PtyCloseNative = ffi.Void Function(ffi.Pointer<PtyContext> ctx);
typedef PtyClose = void Function(ffi.Pointer<PtyContext> ctx);

typedef PtyFreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> ptr);
typedef PtyFree = void Function(ffi.Pointer<ffi.Void> ptr);

// Load the native library
ffi.DynamicLibrary _loadLibrary() {
  // Try environment variable first for flexibility
  final libraryPath = Platform.environment['NATIVE_PTY_LIBRARY_PATH'];
  if (libraryPath != null && libraryPath.isNotEmpty) {
    return ffi.DynamicLibrary.open(libraryPath);
  }

  // Default paths based on platform
  if (Platform.isLinux) {
    return ffi.DynamicLibrary.open('lib/linux/libpty_bridge.so');
  } else if (Platform.isMacOS) {
    return ffi.DynamicLibrary.open('lib/macos/libpty_bridge.dylib');
  } else {
    throw UnsupportedError('Platform ${Platform.operatingSystem} is not supported');
  }
}

/// A native pseudo-terminal (PTY) interface for Dart.
///
/// This class provides a high-level API for spawning processes with a PTY
/// and communicating with them through a Stream interface.
class NativePty {
  late final ffi.DynamicLibrary _lib;
  late final PtyInit _ptyInit;
  late final PtySpawn _ptySpawn;
  late final PtyWrite _ptyWrite;
  late final PtyResize _ptyResize;
  late final PtyClose _ptyClose;
  late final PtyFree _ptyFree;

  ffi.Pointer<PtyContext>? _context;
  late final ffi.NativeCallable<PtyDataCallbackNative> _nativeCallback;
  final StreamController<String> _controller = StreamController<String>();
  late final ByteConversionSink _utf8Sink;
  bool _closed = false;

  /// Creates a new NativePty instance.
  ///
  /// This initializes the FFI bindings and sets up the data callback.
  NativePty() {
    _lib = _loadLibrary();

    _ptyInit = _lib.lookupFunction<PtyInitNative, PtyInit>('pty_init');
    _ptySpawn = _lib.lookupFunction<PtySpawnNative, PtySpawn>('pty_spawn');
    _ptyWrite = _lib.lookupFunction<PtyWriteNative, PtyWrite>('pty_write');
    _ptyResize = _lib.lookupFunction<PtyResizeNative, PtyResize>('pty_resize');
    _ptyClose = _lib.lookupFunction<PtyCloseNative, PtyClose>('pty_close');
    _ptyFree = _lib.lookupFunction<PtyFreeNative, PtyFree>('pty_free');

    // Initialize the PTY system
    _ptyInit();

    // Set up chunked UTF-8 decoder that maintains state between chunks
    // This handles multi-byte UTF-8 characters split across buffer boundaries
    final decoder = const Utf8Decoder(allowMalformed: false);
    _utf8Sink = decoder.startChunkedConversion(
      _StreamStringSink(_controller),
    );

    // Set up the native callback
    _nativeCallback =
        ffi.NativeCallable<PtyDataCallbackNative>.listener(_onData);
  }

  /// Callback for data received from the PTY.
  void _onData(ffi.Pointer<ffi.Uint8> data, int length) {
    try {
      // Convert native memory to Dart bytes
      final bytes = data.asTypedList(length);
      // Use chunked UTF-8 decoder to handle multi-byte characters split across buffers
      // The decoder maintains state and will buffer incomplete sequences
      if (!_closed) {
        _utf8Sink.add(bytes);
      }
    } finally {
      // CRITICAL: Free the C memory now that Dart has copied it
      _ptyFree(data.cast<ffi.Void>());
    }
  }

  /// Spawns a new process with a PTY.
  ///
  /// [command] is the path to the executable to run.
  /// [args] is the list of arguments to pass to the command (including argv[0]).
  /// [environment] is an optional map of environment variables to set for the process.
  /// If null, the current process environment is used.
  ///
  /// Returns true if the spawn was successful, false otherwise.
  bool spawn(String command, List<String> args, {Map<String, String>? environment}) {
    if (_context != null) {
      throw StateError('PTY already spawned');
    }

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

    try {
      _context = _ptySpawn(commandPtr, argvPtr, envpPtr, _nativeCallback.nativeFunction);

      if (_context == null || _context == ffi.nullptr) {
        return false;
      }

      return true;
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
    }
  }

  /// Writes data to the PTY.
  ///
  /// [data] is the string to write to the PTY.
  ///
  /// Returns the number of bytes written, or -1 on error.
  int write(String data) {
    if (_context == null || _context == ffi.nullptr) {
      throw StateError('PTY not spawned');
    }

    final bytes = utf8.encode(data);
    final length = bytes.length;

    // Allocate native memory for the data
    final dataPtr = calloc<ffi.Uint8>(length);
    try {
      // Efficiently copy bytes using asTypedList
      final nativeBytes = dataPtr.asTypedList(length);
      nativeBytes.setAll(0, bytes);

      return _ptyWrite(_context!, dataPtr, length);
    } finally {
      calloc.free(dataPtr);
    }
  }

  /// Resizes the PTY window.
  ///
  /// [rows] is the number of rows (height).
  /// [cols] is the number of columns (width).
  ///
  /// Returns 0 on success, -1 on error.
  int resize(int rows, int cols) {
    if (_context == null || _context == ffi.nullptr) {
      throw StateError('PTY not spawned');
    }

    return _ptyResize(_context!, rows, cols);
  }

  /// Stream of data received from the PTY.
  ///
  /// Data is provided as UTF-8 decoded strings.
  Stream<String> get stream => _controller.stream;

  /// Closes the PTY and cleans up resources.
  ///
  /// This will terminate the child process and close the PTY.
  void close() {
    if (_closed) {
      return;
    }

    _closed = true;

    if (_context != null && _context != ffi.nullptr) {
      _ptyClose(_context!);
      _context = null;
    }

    // Close the UTF-8 sink to flush any pending bytes
    _utf8Sink.close();
    _controller.close();
    _nativeCallback.close();
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
