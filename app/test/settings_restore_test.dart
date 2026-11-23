import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/settings.dart';

void main() {
  test('legacy values win and malformed fields preserve notebook defaults', () {
    final settings = Settings.notebook();
    settings.restore({
      'font_size': 20,
      'fontSize': 44.8,
      'height': -1,
      'ink_thickness': 0.25,
      'ink_softness': 0.3,
      'full_preview': false,
      'enableFullPreview': true,
    });
    expect(settings.values['font_size'], '44');
    expect(settings.values['height'], '2200');
    expect(settings.values['ink_thickness'], '0');
    expect(settings.values['ink_softness'], '0.3');
    expect(settings.fullPreview, isFalse);
    expect(
      (Settings()..restore(settings.toJson())).toJson(),
      settings.toJson(),
    );
  });
}
