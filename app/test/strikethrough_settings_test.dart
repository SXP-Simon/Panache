import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/settings.dart';

void main() {
  test(
    'strikethrough defaults off and preserves probability across toggles',
    () {
      final settings = Settings.notebook();
      Map<String, String> form() =>
          settings.form('draft', preview: true, pdf: false);
      expect(form()['strikethrough_probability'], '0');
      settings.setStrikethroughEnabled(true);
      expect(form()['strikethrough_probability'], '0.005');
      settings.values['strikethrough_probability'] = '0.2';
      settings.setStrikethroughEnabled(false);
      expect(form()['strikethrough_probability'], '0');
      final restored = Settings()..restore(settings.toJson());
      expect(restored.strikethroughEnabled, isFalse);
      restored.setStrikethroughEnabled(true);
      expect(restored.values['strikethrough_probability'], '0.2');
    },
  );

  test('legacy presets preserve their existing strikethrough behavior', () {
    final settings = Settings()..restore({'strikethrough_probability': 0.1});
    expect(settings.strikethroughEnabled, isTrue);
    expect(
      settings.form(
        'text',
        preview: true,
        pdf: false,
      )['strikethrough_probability'],
      '0.1',
    );
    settings.restore({'strikethrough_probability': 0});
    expect(settings.strikethroughEnabled, isFalse);
    expect(Settings().strikethroughEnabled, isFalse);
  });
}
