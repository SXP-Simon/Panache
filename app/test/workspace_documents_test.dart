import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/services/workspace_documents.dart';

class DocumentApi extends HandwritingApi {
  DocumentApi() : super('local://test');
  final importResult = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> importFile(String path, Upload file) =>
      importResult.future;
}

void main() {
  test('preset import preserves the selected font when the source font is unavailable', () {
    final workspace = Workspace()..fonts = ['available.ttf'];
    addTearDown(workspace.dispose);
    workspace.settings.font = 'available.ttf';
    final documents = WorkspaceDocuments(workspace);
    documents.importPreset(
      Upload(
        'preset.json',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({'font_option': 'missing.ttf', 'font_size': 80}),
          ),
        ),
      ),
    );
    expect(workspace.settings.font, 'available.ttf');
    expect(workspace.settings.values['font_size'], '80');
    final exported = jsonDecode(utf8.decode(documents.exportPreset()));
    expect(exported['font_option'], 'available.ttf');
  });

  test('non-object presets fail without changing settings', () {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final previous = workspace.settings.toJson();
    expect(
      () => WorkspaceDocuments(
        workspace,
      ).importPreset(Upload('bad.json', Uint8List.fromList(utf8.encode('[]')))),
      throwsFormatException,
    );
    expect(workspace.settings.toJson(), previous);
  });

  test('background detection ignores a result after the user replaces the background', () async {
    final api = DocumentApi();
    final workspace = Workspace(api: api)
      ..background = Upload('first.png', Uint8List(0));
    addTearDown(workspace.dispose);
    final previous = workspace.settings.values['left_margin'];
    final pending = WorkspaceDocuments(workspace).detectBackground();
    workspace.background = Upload('second.png', Uint8List(0));
    api.importResult.complete({'marginLeft': 123});
    await pending;
    expect(workspace.settings.values['left_margin'], previous);
  });

  test('document responses cannot modify a disposed workspace', () async {
    final api = DocumentApi();
    final workspace = Workspace(api: api)..text = 'Original';
    final pending = WorkspaceDocuments(workspace)
        .importText(Upload('text.txt', Uint8List(0)));
    workspace.dispose();
    api.importResult.complete({'text': 'Late response'});
    await pending;
    expect(workspace.text, 'Original');
  });
}

