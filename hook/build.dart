// Copyright (c) 2025, the native_pty authors.
// Build hook for native_pty library.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.config.buildCodeAssets) {
      final packageName = input.packageName;
      final cbuilder = CBuilder.library(
        name: 'pty_bridge',
        assetName: '$packageName.dart',
        sources: ['src/pty_bridge.c'],
        // Link with util library for PTY functions
        flags: ['-lutil'],
      );
      await cbuilder.run(
        input: input,
        output: output,
        logger: Logger('')
          ..level = Level.ALL
          ..onRecord.listen((record) => print(record.message)),
      );
    }
  });
}
