import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/services/workspace_documents.dart';
import 'package:handwriting_app/services/workspace_storage.dart';

class MemoryStorage implements WorkspaceStorage {
  final data = <String, String>{};
  @override
  String? read(String key) => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }
}

void main() {
  test(
    'standard is the backward-compatible default and unknown presets fall back',
    () {
      final settings = Settings();
      expect(settings.layoutStyle, 'standard');
      settings.layoutStyle = 'homework';
      settings.restore({'font_size': 80});
      expect(settings.layoutStyle, 'standard');
      settings.restore({'layoutStyle': 'unknown'});
      expect(settings.layoutStyle, 'standard');
      settings.restore({'layout_style': 'homework'});
      expect(settings.layoutStyle, 'homework');
    },
  );
  test(
    'switching layout preserves source font background and paper measurements',
    () async {
      final storage = MemoryStorage();
      final workspace = Workspace(storage: storage)
        ..text = '(1) 原文 x₁²'
        ..fonts = ['云烟体.ttf']
        ..background = Upload('paper.png', Uint8List(0));
      addTearDown(workspace.dispose);
      workspace.settings.font = '云烟体.ttf';
      final before = Map<String, String>.of(workspace.settings.values);
      final background = workspace.background;
      workspace.settings.layoutStyle = 'homework';
      workspace.edit();
      await workspace.persistDraft();
      expect(workspace.settings.values, before);
      expect(workspace.background, same(background));
      expect(workspace.text, '(1) 原文 x₁²');
      final saved = jsonDecode(
        storage.data['flutter.workspace']!,
      ) as Map<String, dynamic>;
      final restored = Settings()
        ..restore(saved['settings'] as Map<String, dynamic>);
      expect(restored.layoutStyle, 'homework');
      expect(restored.font, '云烟体.ttf');
      expect(
        restored.form(
          workspace.text,
          preview: true,
          pdf: false,
        )['layout_style'],
        'homework',
      );
      final documents = WorkspaceDocuments(workspace);
      final exported = documents.exportPreset();
      workspace.settings.layoutStyle = 'standard';
      documents.importPreset(Upload('preset.json', exported));
      expect(workspace.settings.layoutStyle, 'homework');
      expect(workspace.settings.values, before);
    },
  );
}
