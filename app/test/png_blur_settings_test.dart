import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/widgets/settings/png_blur_settings.dart';
import 'package:handwriting_app/widgets/settings/settings_fields.dart';

void main() {
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
