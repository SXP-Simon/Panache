import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/png_blur.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/widgets/settings/png_blur_settings.dart';
import 'package:handwriting_app/widgets/settings/settings_fields.dart';

void main() {
  test('all PNG finishes use the same handwriting for preview and ZIP', () {
    final settings = Settings.notebook();
    for (final mode in PngBlurMode.values) {
      settings.pngBlur.mode = mode;
      for (final preview in [true, false]) {
        final fields = settings.form('例 7', preview: preview, pdf: false);
        expect(fields['seed'], '0', reason: '$mode, preview=$preview');
      }
    }
    final legacy = settings.form(
      '例 7',
      preview: true,
      pdf: false,
      supportsPngBlur: false,
    );
    expect(legacy.containsKey('seed'), isFalse);
    expect(legacy.containsKey('export_blur_gradient'), isFalse);
    expect(
      settings.form('例 7', preview: false, pdf: true).containsKey('seed'),
      isFalse,
    );
  });

  testWidgets(
    'paper controls set independent anchors for PNG preview and export',
    (tester) async {
      final settings = Settings.notebook();
      Map<String, String> form({bool pdf = false, bool preview = true}) =>
          settings.form('Example', preview: preview, pdf: pdf);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (_, change) => PngBlurSettings(
                  fields: SettingsFields(
                    settings,
                    0,
                    false,
                    () => change(() {}),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(form().containsKey('export_blur_px'), isFalse);
      await tester.tap(find.text('Uniform'));
      await tester.pumpAndSettle();
      expect(form()['export_blur_px'], '0.6');
      await tester.tap(find.text('Two-point gradient'));
      await tester.pumpAndSettle();
      final map = find.byKey(const ValueKey('png-blur-page'));
      await tester.tap(map);
      await tester.pump();
      expect(settings.pngBlur.from.y, .5);
      await tester.tap(find.text('End B'));
      await tester.pumpAndSettle();
      await tester.tap(map);
      await tester.pump();
      expect(
        find.text('Choose different start and end positions.'),
        findsOneWidget,
      );
      final box = tester.getRect(map);
      await tester.tapAt(
        box.topLeft + Offset(.75 * box.width, .8 * box.height),
      );
      await tester.pump();
      final fields = form();
      expect(fields.containsKey('export_blur_px'), isFalse);
      expect(jsonDecode(fields['export_blur_gradient']!), {
        'from': {'x': .5, 'y': .5, 'sigma_px': 1.2},
        'to': {'x': .75, 'y': .8, 'sigma_px': 0.0},
      });
      expect(
        form(preview: false)['export_blur_gradient'],
        fields['export_blur_gradient'],
      );
      expect(
        form(pdf: true, preview: false).containsKey('export_blur_gradient'),
        isFalse,
      );
      final restored = Settings()..restore(settings.toJson());
      expect(restored.pngBlur.fields, settings.pngBlur.fields);
      expect(tester.takeException(), isNull);
    },
  );
}
