import 'dart:io';

import 'package:crypto/crypto.dart';

import 'update_model.dart';

/// A package becomes visible only after complete length and digest verification.
Future<String> saveVerifiedUpdate({
  required Stream<List<int>> stream,
  required Directory root,
  required VerifiedPackage package,
  required DownloadCancellation cancellation,
  required void Function(int, int) progress,
}) async {
  cancellation.check();
  final asset = package.asset;
  if (!RegExp(r'^Flutter-Panache-[\w.\-]+$').hasMatch(asset.name) ||
      asset.size <= 0 ||
      asset.size > 2 * 1024 * 1024 * 1024) {
    throw const UpdateException(UpdateProblem.verification);
  }
  final directory = await root.createTemp('download-');
  final partial = File('${directory.path}/${asset.name}.part');
  final destination = File('${directory.path}/${asset.name}');
  RandomAccessFile? sink;
  var success = false;
  try {
    sink = await partial.open(mode: FileMode.write);
    var received = 0;
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      cancellation.check();
      received += chunk.length;
      if (received > asset.size) {
        throw const UpdateException(UpdateProblem.verification);
      }
      await sink.writeFrom(chunk);
      progress(received, asset.size);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    cancellation.check();
    if (received != asset.size ||
        (await sha256.bind(partial.openRead()).first).toString() !=
            package.sha256) {
      throw const UpdateException(UpdateProblem.verification);
    }
    cancellation.check();
    await partial.rename(destination.path);
    cancellation.check();
    success = true;
    return destination.path;
  } finally {
    try {
      await sink?.close();
    } catch (_) {
      /* Keep the original download/write error. */
    }
    if (!success) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } on FileSystemException {
        // The private unfinished file is never offered to the installer.
      }
    }
  }
}
