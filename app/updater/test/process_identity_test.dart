import 'dart:io';

import 'package:panache_updater/process_identity.dart';
import 'package:panache_updater/protocol.dart';
import 'package:test/test.dart';

Future<Process> child() async {
  final directory = await Directory.systemTemp.createTemp('panache-identity-');
  addTearDown(() => directory.delete(recursive: true));
  final script = File('${directory.path}/child.dart');
  await script.writeAsString('''
import 'dart:async';
import 'dart:io';
void main() {
stdout.writeln('READY');
Timer.periodic(const Duration(seconds: 1), (_) {});
}
''');
  final process = await Process.start(Platform.resolvedExecutable, [
    script.path,
  ]);
  await process.stdout.first.timeout(const Duration(seconds: 20));
  // Drain diagnostics and always reap the owned child after a failed test.
  process.stderr.drain<void>();
  addTearDown(() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  });
  return process;
}

void main() {
  test('native self identity persists exact executable and creation time', () {
    final identity = ProcessIdentity.capture(pid)!;
    expect(identity.pid, pid);
    expect(identity.executable, isNotEmpty);
    expect(identity.started, startsWith('${Platform.operatingSystem}:'));
    expect(identity.matchesLive(), isTrue);
    final restored = ProcessIdentity.fromJson(identity.toJson());
    expect(restored.matchesLive(), isTrue);
    expect(restored.toJson(), identity.toJson());
  });

  test('invalid and incomplete persisted identities are rejected', () {
    final data = ProcessIdentity.capture(pid)!.toJson();
    for (final value in [
      <String, Object>{...data, 'pid': 0},
      <String, Object>{...data, 'pid': -1},
      <String, Object>{...data, 'pid': 0x80000000},
      <String, Object>{...data, 'executable': 'relative.exe'},
      <String, Object>{...data, 'executable': '/bad\x00name'},
      <String, Object>{...data, 'started': ''},
      <String, Object>{...data, 'started': 'unknown:1'},
      <String, Object>{...data, 'command': 'arbitrary'},
    ]) {
      expect(
        () => ProcessIdentity.fromJson(value),
        throwsA(isA<UpdaterFailure>()),
      );
    }
  });

  test('never signals the updater itself', () async {
    final identity = ProcessIdentity.capture(pid)!;
    await expectLater(identity.stopExact(), throwsA(isA<UpdaterFailure>()));
    expect(identity.matchesLive(), isTrue);
  });

  test('a just-terminated child is safely treated as gone during native handle teardown', () async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final process = await child();
      final identity = ProcessIdentity.capture(process.pid)!;
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await identity.stopExact();
      expect(
        await identity.waitGone(timeout: const Duration(seconds: 2)),
        isTrue,
      );
    }
  });

  test(
    'creation-time or executable mismatch cannot terminate a live child',
    () async {
      final process = await child();
      final identity = ProcessIdentity.capture(process.pid)!;
      final wrongTime = ProcessIdentity(
        identity.pid,
        identity.executable,
        '${identity.started}0',
      );
      final wrongExecutable = ProcessIdentity(
        identity.pid,
        '${identity.executable}.other',
        identity.started,
      );
      for (final mismatch in [wrongTime, wrongExecutable]) {
        expect(mismatch.matchesLive(), isFalse);
        await mismatch.stopExact();
        expect(identity.matchesLive(), isTrue);
      }
      expect(
        await identity.waitGone(timeout: const Duration(milliseconds: 60)),
        isFalse,
      );
      await identity.stopExact();
      await process.exitCode.timeout(const Duration(seconds: 5));
      expect(
        await identity.waitGone(timeout: const Duration(seconds: 1)),
        isTrue,
      );
      expect(ProcessIdentity.capture(process.pid), isNull);
      await identity.stopExact();
    },
  );
}
