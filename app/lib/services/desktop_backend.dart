import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'api.dart';

bool get usesMobileBackend => Platform.isAndroid || Platform.isIOS;
bool get usesDesktopBackend =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Owns only the bundled process. Closing stdin also covers a crashed parent.
class DesktopBackend {
  Process? _process;
  bool _stopping = false;
  Future<int>? exited;
  int? get pid => _process?.pid;

  static String bundledExecutable() {
    final directory = File(Platform.resolvedExecutable).parent.path;
    final root = Platform.isMacOS ? '$directory/../Resources' : directory;
    return '$root/backend/handwriting-server${Platform.isWindows ? '.exe' : ''}';
  }

  Future<HandwritingApi> start({
    String? executable,
    String? dataDirectory,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_process != null) throw StateError('Backend already started');
    final binary = executable ?? bundledExecutable();
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final ready = Completer<String>();
    var diagnostic = '';
    try {
      _process = await Process.start(
        binary,
        const [],
        environment: {
          'HANDWRITING_LISTEN_ADDR': '127.0.0.1:0',
          'HANDWRITING_ACCESS_TOKEN': token,
          'HANDWRITING_DESKTOP_SIDECAR': '1',
          'HANDWRITING_FONT_DIR': '${File(binary).parent.path}/font_assets',
          'HANDWRITING_WEB_DIR': '',
          'HANDWRITING_DATA_DIR': ?dataDirectory,
        },
      );
      final process = _process!;
      // Drain both pipes throughout the process lifetime to prevent deadlocks.
      process.stderr.transform(utf8.decoder).listen((text) {
        diagnostic = '$diagnostic$text';
        if (diagnostic.length > 2048) {
          diagnostic = diagnostic.substring(diagnostic.length - 2048);
        }
      });
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!line.startsWith('HANDWRITING_READY ') || ready.isCompleted) {
                return;
              }
              try {
                final base =
                    (jsonDecode(line.substring(18)) as Map)['base'] as String;
                final uri = Uri.parse(base);
                if (uri.scheme != 'http' ||
                    uri.host != '127.0.0.1' ||
                    uri.port == 0) {
                  throw const FormatException('Invalid backend address');
                }
                ready.complete(base);
              } catch (e, stack) {
                ready.completeError(e, stack);
              }
            },
            onError: (Object e, StackTrace stack) {
              if (!ready.isCompleted) ready.completeError(e, stack);
            },
          );
      exited = process.exitCode;
      unawaited(
        exited!.then((code) {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('Backend exited ($code): $diagnostic'),
            );
          }
        }),
      );
      final base = await ready.future.timeout(timeout);
      final client = http.Client();
      try {
        final response = await client
            .get(
              Uri.parse('$base/api/health'),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(timeout);
        if (response.statusCode != 200) {
          throw StateError(
            'Backend health check failed (${response.statusCode})',
          );
        }
      } finally {
        client.close();
      }
      return HandwritingApi(base, accessToken: token);
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null || _stopping) return;
    _stopping = true;
    try {
      // EOF requests graceful cancellation on Windows as well as Unix.
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    } finally {
      _process = null;
      _stopping = false;
    }
  }
}
