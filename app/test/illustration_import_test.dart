import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/screens/dialogs/illustration_dialog.dart';
import 'package:handwriting_app/services/illustration_import.dart';
import 'package:handwriting_app/utils/image_data.dart';

class _Picker extends FilePicker {
  _Picker(this.result);
  final FilePickerResult? result;
  bool? dataRequested, streamRequested;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    dataRequested = withData;
    streamRequested = withReadStream;
    return result;
  }
}

void main() {
  test(
    'picker cancellation requests streaming without reading the file',
    () async {
      final picker = _Picker(null);
      expect(await pickIllustration(picker: picker), isNull);
      expect(picker.dataRequested, isFalse);
      expect(picker.streamRequested, isTrue);
    },
  );
  test('declared oversize is rejected before stream subscription', () async {
    var read = false;
    Stream<List<int>> source() async* {
      read = true;
      yield [1];
    }

    final file = PlatformFile(
      name: 'large.png',
      size: maxIllustrationImportBytes + 1,
      readStream: source(),
    );
    await expectLater(readIllustrationFile(file), throwsFormatException);
    expect(read, isFalse);
  });
  test(
    'unknown or dishonest size cannot bypass bounded stream reading',
    () async {
      var chunks = 0;
      Stream<List<int>> source() async* {
        for (var i = 0; i < 3; i++) {
          chunks++;
          yield Uint8List(maxIllustrationImportBytes ~/ 2 + 1);
        }
      }

      await expectLater(
        readIllustrationFile(
          PlatformFile(name: 'cloud.jpg', size: 0, readStream: source()),
        ),
        throwsFormatException,
      );
      expect(chunks, 2);
      final file = await readIllustrationFile(
        PlatformFile(
          name: 'small.png',
          size: 0,
          readStream: Stream.value([1, 2, 3]),
        ),
      );
      expect(file.bytes, [1, 2, 3]);
      await expectLater(
        readIllustrationFile(PlatformFile(name: 'missing.png', size: 10)),
        throwsFormatException,
      );
      await expectLater(
        readIllustrationFile(
          PlatformFile(
            name: 'empty.png',
            size: 0,
            readStream: const Stream.empty(),
          ),
        ),
        throwsFormatException,
      );
    },
  );
  test('oversized restored data is rejected before base64 allocation', () {
    final huge = 'A' * ((((maxRestoredIllustrationBytes + 2) ~/ 3) * 4) + 129);
    expect(decodeImageData(huge), isNull);
  });
  testWidgets('corrupt but base64-valid illustration cannot be applied', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showIllustrationDialog(
                context,
                source: 'data:image/png;base64,AQID',
                removable: true,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('illustration-apply')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('illustration-remove')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
