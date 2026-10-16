import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/widgets/workbench_settings.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final locale in [const Locale('zh'), const Locale('en')]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('settings labels fit 320px $brightness $locale $scale', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(320, 800);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final settings = Settings()..font = 'test.ttf';
          void noop() {}
          await tester.pumpWidget(
            MaterialApp(
              theme: handwritingTheme(brightness),
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: WorkbenchSettings(
                  settings: settings,
                  fonts: const ['test.ttf'],
                  fontFile: null,
                  background: null,
                  settingsRevision: 0,
                  locked: false,
                  onEdited: noop,
                  onSelectFont: (_) {},
                  onColorSelected: (_) {},
                  onUploadFont: noop,
                  onRemoveFont: noop,
                  onDefaultPreset: noop,
                  onSmallPreset: noop,
                  onSavePreset: noop,
                  onLoadPreset: noop,
                  onExportPreset: noop,
                  onImportPreset: noop,
                  onUploadBackground: noop,
                  onDetectBackground: noop,
                  onRemoveBackground: noop,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(WorkbenchSettings));
          final l = AppLocalizations.of(context)!;
          final viewport = find.byType(ListView);
          // The first label must occupy space inside the scroll viewport.
          final fontLabel = find.text(l.font);
          expect(
            tester.getRect(fontLabel).top,
            greaterThanOrEqualTo(tester.getRect(viewport).top),
          );
          expect(
            tester.getRect(fontLabel).bottom,
            lessThan(
              tester.getRect(find.byType(DropdownButtonFormField<String>)).top,
            ),
          );
          final layout = find.text(l.layout);
          await tester.scrollUntilVisible(
            layout,
            200,
            scrollable: find
                .descendant(of: viewport, matching: find.byType(Scrollable))
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(layout);
          await tester.pump(const Duration(milliseconds: 80));
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
          await tester.tap(layout);
          await tester.pumpAndSettle();
          final input = find.byKey(const ValueKey('font_size-0'));
          await tester.ensureVisible(input);
          await tester.pumpAndSettle();
          final label = find
              .descendant(
                of: find
                    .ancestor(
                      of: input,
                      matching: find.byType(SettingsFieldLabel),
                    )
                    .first,
                matching: find.byType(Text),
              )
              .first;
          expect(
            tester.getRect(label).bottom,
            lessThan(tester.getRect(input).top),
          );
          if (scale == 2) {
            // Accessibility text gets a full-width field instead of squeezed columns.
            expect(tester.getSize(input).width, greaterThan(250));
          }
          await tester.tap(input);
          tester.view.viewInsets = const FakeViewPadding(bottom: 250);
          await tester.pumpAndSettle();
          await tester.enterText(input, '72');
          expect(settings.values['font_size'], '72');
          FocusManager.instance.primaryFocus?.unfocus();
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
