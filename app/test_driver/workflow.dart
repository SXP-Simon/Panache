import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Directory(
    Platform.environment['PANACHE_SCREENSHOTS'] ?? 'build/workflow-screenshots',
  );
  await output.create(recursive: true);
  await integrationDriver(
    onScreenshot: (name, bytes, [arguments]) async {
      final filename = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      await File('${output.path}/$filename.png')
          .writeAsBytes(bytes, flush: true);
      return true;
    },
    responseDataCallback: null,
  );
}
