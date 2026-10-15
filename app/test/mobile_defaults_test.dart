import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:handwriting_app/services/workspace_storage.dart';

class DefaultStorage implements WorkspaceStorage {
  final values = <String, String>{};
  @override
  String? read(String key) => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class DefaultApi extends HandwritingApi {
  DefaultApi() : super('local://defaults');
  @override
  Future<dynamic> getJson(String path) async =>
      path == '/api/fonts_info' ? ['selected.ttf'] : {'version': 'test'};
}

void main() {
  test(
    'notebook defaults target portrait mobile writing without touching fonts',
    () {
      final settings = Settings.notebook();
      expect(settings.valid, isTrue);
      expect(settings.font, isNull);
      expect(settings.values, containsPair('width', '1600'));
      expect(settings.values, containsPair('height', '2200'));
      expect(settings.values, containsPair('font_size', '70'));
      expect(settings.values, containsPair('line_spacing', '120'));
      expect(settings.values, containsPair('word_spacing', '2'));
      expect(settings.values, containsPair('strikethrough_probability', '0'));
      expect(settings.values, containsPair('perturb_x_sigma', '1'));
      expect(settings.values, containsPair('perturb_y_sigma', '1'));
      final width = int.parse(settings.values['width']!);
      final height = int.parse(settings.values['height']!);
      final horizontalMargins =
          int.parse(settings.values['left_margin']!) +
          int.parse(settings.values['right_margin']!);
      final verticalMargins =
          int.parse(settings.values['top_margin']!) +
          int.parse(settings.values['bottom_margin']!);
      final characterCell =
          int.parse(settings.values['font_size']!) +
          int.parse(settings.values['word_spacing']!);
      expect((width - horizontalMargins) ~/ characterCell, 20);
      expect(
        (height - verticalMargins) ~/
            int.parse(settings.values['line_spacing']!),
        16,
      );
      expect(settings.underlined, Settings().underlined);
    },
  );

  test(
    'mobile startup uses injected notebook defaults when no draft exists',
    () async {
      final workspace = Workspace(
        api: DefaultApi(),
        storage: DefaultStorage(),
        settingsFactory: Settings.notebook,
      );
      await workspace.initialize();
      expect(workspace.settings.values, Settings.notebook().values);
      expect(workspace.settings.font, 'selected.ttf');
      workspace.dispose();
      await workspace.persist();
    },
  );

  test(
    'existing full mobile draft keeps all custom paper and writing values',
    () async {
      final storage = DefaultStorage();
      final custom = Settings()
        ..font = 'selected.ttf'
        ..underlined = false;
      custom.values.addAll({
        'width': '2100',
        'height': '2800',
        'font_size': '96',
        'line_spacing': '170',
        'word_spacing': '4',
        'left_margin': '130',
        'right_margin': '140',
        'top_margin': '150',
        'bottom_margin': '160',
      });
      storage.values['flutter.workspace'] = jsonEncode({
        'text': '继续我的自定义作业',
        'settings': custom.toJson(),
      });
      final workspace = Workspace(
        api: DefaultApi(),
        storage: storage,
        settingsFactory: Settings.notebook,
      );
      await workspace.initialize();
      expect(workspace.text, '继续我的自定义作业');
      expect(workspace.settings.toJson(), custom.toJson());
      workspace.dispose();
      await workspace.persist();
    },
  );

  test('desktop defaults remain unchanged and new reset instances do not share state', () {
    final desktop = Workspace(api: DefaultApi());
    final mobile = Workspace(
      api: DefaultApi(),
      settingsFactory: Settings.notebook,
    );
    expect(desktop.settings.toJson(), Settings().toJson());
    expect(desktop.settings.values['font_size'], '124');
    expect(desktop.settings.values['width'], '2481');
    mobile.settings.values['font_size'] = '99';
    final reset = mobile.createDefaultSettings();
    expect(reset.values['font_size'], '70');
    reset.values['font_size'] = '80';
    expect(mobile.createDefaultSettings().values['font_size'], '70');
    expect(mobile.settings.values['font_size'], '99');
    desktop.dispose();
    mobile.dispose();
  });
}
