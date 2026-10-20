import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/updates/update_download.dart';
import 'package:handwriting_app/services/updates/update_model.dart';

void main() {
  late Directory directory;
  final bytes = List.generate(65536, (index) => index % 256);
  VerifiedPackage package({
    int? size,
    String? hash,
    String name = 'Flutter-Panache-1.7.0-windows-x64.zip',
  }) => VerifiedPackage(
    ReleaseAsset(
      name,
      Uri.parse(
        'https://github.com/SXP-Simon/Panache/releases/download/v1.7.0/$name',
      ),
      size ?? bytes.length,
    ),
    hash ?? sha256.convert(bytes).toString(),
    1007000,
  );
  setUp(
    () async => directory = await Directory.systemTemp.createTemp(
      'panache-update-test-',
    ),
  );
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  test(
    'writes complete package atomically and reports real streamed progress',
    () async {
      final progress = <int>[];
      final result = await saveVerifiedUpdate(
        stream: Stream.fromIterable([
          bytes.sublist(0, 32000),
          bytes.sublist(32000),
        ]),
        root: directory,
        package: package(),
        cancellation: DownloadCancellation(),
        progress: (done, total) {
          progress.add(done);
          expect(total, bytes.length);
        },
      );
      expect(await File(result).readAsBytes(), bytes);
      expect(progress, [32000, bytes.length]);
      expect(
        await directory
            .list(recursive: true)
            .where((item) => item.path.endsWith('.part'))
            .length,
        0,
      );
    },
  );
  test('truncated oversized corrupted empty and unsafe packages leave no partial files', () async {
    for (final value in [
      package(size: bytes.length + 1),
      package(size: bytes.length - 1),
      package(hash: List.filled(64, '0').join()),
      package(size: 0),
      package(name: '../../other.zip'),
    ]) {
      await expectLater(
        saveVerifiedUpdate(
          stream: Stream.value(bytes),
          root: directory,
          package: value,
          cancellation: DownloadCancellation(),
          progress: (_, _) {},
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.problem,
            'problem',
            UpdateProblem.verification,
          ),
        ),
      );
      expect(await directory.list().length, 0);
    }
  });
  test('cancelled stream and network failures leave no installable or partial package', () async {
    final cancellation = DownloadCancellation();
    Stream<List<int>> chunks() async* {
      yield bytes.sublist(0, 100);
      cancellation.cancel();
      yield bytes.sublist(100);
    }

    await expectLater(
      saveVerifiedUpdate(
        stream: chunks(),
        root: directory,
        package: package(),
        cancellation: cancellation,
        progress: (_, _) {},
      ),
      throwsA(isA<UpdateException>()),
    );
    expect(await directory.list().length, 0);
    await expectLater(
      saveVerifiedUpdate(
        stream: Stream.error(const SocketException('offline')),
        root: directory,
        package: package(),
        cancellation: DownloadCancellation(),
        progress: (_, _) {},
      ),
      throwsA(isA<SocketException>()),
    );
    expect(await directory.list().length, 0);
  });
  test('cancelling at the final byte cannot publish a ready package', () async {
    final cancellation = DownloadCancellation();
    await expectLater(
      saveVerifiedUpdate(
        stream: Stream.value(bytes),
        root: directory,
        package: package(),
        cancellation: cancellation,
        progress: (_, _) => cancellation.cancel(),
      ),
      throwsA(isA<UpdateException>()),
    );
    expect(await directory.list().length, 0);
  });
  test(
    'concurrent downloads use separate private staging directories',
    () async {
      final paths = await Future.wait(
        List.generate(
          2,
          (_) => saveVerifiedUpdate(
            stream: Stream.value(bytes),
            root: directory,
            package: package(),
            cancellation: DownloadCancellation(),
            progress: (_, _) {},
          ),
        ),
      );
      expect(paths[0], isNot(paths[1]));
      expect(await File(paths[0]).readAsBytes(), bytes);
      expect(await File(paths[1]).readAsBytes(), bytes);
    },
  );
}
