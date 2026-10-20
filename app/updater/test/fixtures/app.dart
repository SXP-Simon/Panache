import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:panache_updater/client.dart';

Future<void> main(List<String> arguments) async {
  final running = RunningInstallation.detect();
  final resources = Platform.isMacOS
      ? p.join(running.runtime, 'Contents', 'Resources')
      : running.runtime;
  final mode = File(p.join(resources, 'mode')).readAsStringSync();
  final transaction = Platform.environment['PANACHE_UPDATE_TRANSACTION'] ?? '';
  if (transaction.isEmpty) {
    if (arguments.contains('--hold')) {
      stdout.writeln('READY');
      await stdin.drain<void>();
      return;
    }
    File(
      p.join(p.dirname(running.root), 'reopened'),
    ).writeAsStringSync(Platform.environment['PANACHE_UPDATE_FAILURE'] ?? '');
    return;
  }
  if (mode == 'crash') exit(2);
  final support = p.dirname(p.dirname(p.dirname(transaction)));
  final startup = DesktopUpdateStartup.read(support)!;
  Process? backend;
  if (mode.endsWith('sidecar')) {
    final executable = p.join(
      running.runtime,
      Platform.isMacOS
          ? 'Contents/Resources/backend/handwriting-server'
          : 'backend/handwriting-server${Platform.isWindows ? '.exe' : ''}',
    );
    backend = await Process.start(executable, []);
    await backend.stdout.first;
    backend.stderr.drain<void>().ignore();
  }
  startup.recordStarted(sidecarPid: backend?.pid);
  if (mode.startsWith('healthy')) startup.acknowledge(running.info.version);
  if (mode == 'bad-ack') {
    File(p.join(transaction, 'healthy.json'))
        .writeAsStringSync('{"ready":true}');
  }
  await Future<void>.delayed(const Duration(minutes: 2));
}
