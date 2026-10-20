import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:panache_updater/process_identity.dart';
import 'package:panache_updater/protocol.dart';
import 'package:test/test.dart';

Future<Process> child({bool untilEof = false}) async {
  final directory = await Directory.systemTemp.createTemp('panache-identity-');
  addTearDown(() => directory.delete(recursive: true));
  final script = File('${directory.path}/child.dart');
  await script.writeAsString('''
import 'dart:async';
import 'dart:io';
void main() async {
stdout.writeln('READY');
${untilEof ? 'await stdin.drain<void>();' : 'Timer.periodic(const Duration(seconds: 1), (_) {});'}
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
  test('stdin EOF racing exact stop and observation never becomes an identity error', () async {
    for (var attempt = 0; attempt < 12; attempt++) {
      final process = await child(untilEof: true);
      final identity = ProcessIdentity.capture(process.pid)!;
      final observed = identity.waitGone(timeout: const Duration(seconds: 5));
      final closing = process.stdin.close();
      await identity.stopExact();
      await closing;
      await process.exitCode;
      expect(await observed, true);
      expect(
        await identity.waitGone(timeout: const Duration(seconds: 1)),
        true,
      );
    }
  });
  test('Linux retains the task directory for a zombie without treating it as a live executable', () async {
    if (!Platform.isLinux) return;
    final parent = await Process.start('python3', [
      '-u',
      '-c',
      r"""
import os, sys, time
r, w = os.pipe()
child = os.fork()
if child == 0:
    os.close(w)
    os.read(r, 1)
    os._exit(0)
os.close(r)
print(child, flush=True)
sys.stdin.readline()
os.write(w, b'x')
for _ in range(500):
    with open('/proc/%s/stat' % child) as stream:
        text = stream.read()
    if text[text.rfind(') ') + 2:].startswith('Z '):
        break
    time.sleep(.002)
print('ZOMBIE', flush=True)
sys.stdin.readline()
os.waitpid(child, 0)
""",
    ]);
    parent.stderr.drain<void>().ignore();
    final lines = StreamIterator(
      parent.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(() async {
      await parent.stdin.close();
      await parent.exitCode;
      await lines.cancel();
    });
    expect(await lines.moveNext(), true);
    final childPid = int.parse(lines.current);
    final identity = ProcessIdentity.capture(childPid)!;
    parent.stdin.writeln('exit');
    await parent.stdin.flush();
    expect(await lines.moveNext(), true);
    expect(lines.current, 'ZOMBIE');
    expect(Directory('/proc/$childPid').existsSync(), true);
    expect(ProcessIdentity.capture(childPid), isNull);
    expect(await identity.waitGone(timeout: const Duration(seconds: 1)), true);
    await identity.stopExact();
    expect(Directory('/proc/$childPid').existsSync(), true);
    parent.stdin.writeln('reap');
    await parent.stdin.flush();
    expect(await parent.exitCode, 0);
  });
  test(
    'Linux permission denial for a live process is never reported as gone',
    () async {
      if (!Platform.isLinux) return;
      final process = await Process.start('python3', [
        '-u',
        '-c',
        r"""
import ctypes, sys
print('READY', flush=True)
sys.stdin.readline()
if ctypes.CDLL(None).prctl(4, 0) != 0:
    raise RuntimeError('PR_SET_DUMPABLE failed')
print('PRIVATE', flush=True)
sys.stdin.readline()
""",
      ]);
      process.stderr.drain<void>().ignore();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        await process.stdin.close();
        await process.exitCode;
        await lines.cancel();
      });
      expect(await lines.moveNext(), true);
      final identity = ProcessIdentity.capture(process.pid)!;
      process.stdin.writeln('private');
      await process.stdin.flush();
      expect(await lines.moveNext(), true);
      expect(lines.current, 'PRIVATE');
      expect(
        identity.matchesLive,
        throwsA(
          predicate(
            (e) => e is UpdaterFailure && e.code == 'process_identity_denied',
          ),
        ),
      );
      expect(
        await identity.waitGone(timeout: const Duration(milliseconds: 150)),
        false,
      );
      await expectLater(
        identity.stopExact(timeout: const Duration(milliseconds: 150)),
        throwsA(
          predicate(
            (e) => e is UpdaterFailure && e.code == 'process_identity_denied',
          ),
        ),
      );
      process.stdin.writeln('exit');
      await process.stdin.flush();
      await process.exitCode;
      expect(await identity.waitGone(), true);
    },
  );
}
