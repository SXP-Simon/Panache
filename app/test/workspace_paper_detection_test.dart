import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/services/workspace_documents.dart';

class PaperApi extends HandwritingApi {
  PaperApi() : super('local://test');
  final requests = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> importFile(String path, Upload file) {
    final pending = Completer<Map<String, dynamic>>();
    requests.add(pending);
    return pending.future;
  }
}

Map<String, dynamic> result() => {
  'marginLeft': 10,
  'marginRight': 10,
  'marginTop': 80,
  'marginBottom': 30,
  'lineSpacing': 70,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PaperApi api;
  late Workspace workspace;
  setUp(() {
    api = PaperApi();
    workspace = Workspace(api: api)
      ..background = Upload('paper.png', Uint8List(0));
  });
  tearDown(() => workspace.dispose());
  test(
    'legacy measurements subtract detected spacing, not previous spacing',
    () async {
      workspace.settings.values['line_spacing'] = '200';
      final pending = WorkspaceDocuments(workspace).detectBackground();
      api.requests.single.complete(result());
      expect(await pending, isTrue);
      expect(workspace.settings.values['top_margin'], '10');
      expect(workspace.settings.values['line_spacing'], '70');
    },
  );
  test('line near top edge advances to the next writable baseline', () async {
    final pending = WorkspaceDocuments(workspace).detectBackground();
    api.requests.single.complete(result()..['marginTop'] = 20);
    await pending;
    expect(workspace.settings.values['top_margin'], '20');
  });
  test('manual settings edits invalidate a pending detection', () async {
    final pending = WorkspaceDocuments(workspace).detectBackground();
    workspace.settings.values['top_margin'] = '777';
    api.requests.single.complete(result());
    expect(await pending, isFalse);
    expect(workspace.settings.values['top_margin'], '777');
  });
  test(
    'older requests cannot overwrite newer identification even with same image',
    () async {
      final first = WorkspaceDocuments(workspace).detectBackground();
      final second = WorkspaceDocuments(workspace).detectBackground();
      api.requests[1].complete(result()..['marginLeft'] = 30);
      expect(await second, isTrue);
      api.requests[0].complete(result()..['marginLeft'] = 90);
      expect(await first, isFalse);
      expect(workspace.settings.values['left_margin'], '30');
    },
  );
  test(
    'only oversized fonts shrink and replacing the image resets grid alignment',
    () async {
      workspace.settings.values['font_size'] = '160';
      final pending = WorkspaceDocuments(workspace).detectBackground();
      api.requests.single.complete(result());
      await pending;
      expect(workspace.settings.values['font_size'], '50');
      expect(workspace.backgroundRuled, isTrue);
      workspace.background = Upload('replacement.png', Uint8List(0));
      expect(workspace.backgroundRuled, isFalse);
    },
  );
  test('small selected font survives identification', () async {
    workspace.settings.values['font_size'] = '25';
    final pending = WorkspaceDocuments(workspace).detectBackground();
    api.requests.single.complete(result());
    await pending;
    expect(workspace.settings.values['font_size'], '25');
  });
  for (final invalid in <Map<String, dynamic>>[
    {'lineSpacing': 0},
    {'marginRight': -1},
    {'marginLeft': double.nan},
    {'marginTop': 'bad'},
    {'imageWidth': 10, 'imageHeight': 100},
    {'imageWidth': 100},
    {'correctedBackground': 'invalid', 'imageWidth': 800, 'imageHeight': 1000},
  ]) {
    test('invalid detection $invalid applies no partial settings', () async {
      final before = workspace.settings.toJson();
      final background = workspace.background;
      final pending = WorkspaceDocuments(workspace).detectBackground();
      api.requests.single.complete(result()..addAll(invalid));
      await expectLater(pending, throwsFormatException);
      expect(workspace.settings.toJson(), before);
      expect(workspace.background, same(background));
    });
  }
  testWidgets('validated corrected PNG and its measurements apply atomically', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffeeeeee), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(800, 1000);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final pending = WorkspaceDocuments(workspace).detectBackground();
      api.requests.single.complete(
        result()..addAll({
          'layoutTopMargin': 12,
          'layoutBottomMargin': 15,
          'imageWidth': 800,
          'imageHeight': 1000,
          'correctedBackground': base64Encode(data!.buffer.asUint8List()),
        }),
      );
      expect(await pending, isTrue);
      expect(workspace.background!.name, 'aligned-paper.png');
      expect(workspace.settings.values['top_margin'], '12');
      expect(workspace.settings.values['bottom_margin'], '15');
      expect(workspace.settings.values['width'], '800');
    });
  });
}
