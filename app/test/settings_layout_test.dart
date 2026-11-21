import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/models/settings.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';
import 'package:handwriting_app/widgets/workbench_settings.dart';
import 'package:handwriting_app/widgets/ink_parameter_controls.dart';

void main() {
  testWidgets('mobile numeric fields show the entire value beside its unit', (
    tester,
  ) async {
    for (final scale in [1.0, 2.0]) {
      for (final (id, parameter, value, unit) in [
        ('latin', latinScaleParameter, 100.0, '%'),
        ('opacity', inkParameters[0], 100.0, '%'),
        ('thickness', inkParameters[1], -2.0, 'px'),
        ('softness', inkParameters[2], 1.0, 'px'),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: handwritingTheme(Brightness.light),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 260,
                    child: NumericSlider(
                      key: ValueKey(id),
                      id: id,
                      label: '参数',
                      parameter: parameter,
                      value: value,
                      unit: unit,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byType(EditableText);
        final editable = tester.state<EditableTextState>(field).renderEditable;
        final text = tester.widget<EditableText>(field).controller.text;
        final boxes = editable.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: text.length),
        );
        expect(boxes, isNotEmpty);
        for (final box in boxes) {
          expect(
            box.left,
            greaterThanOrEqualTo(0),
            reason: '$id at scale $scale',
          );
          expect(
            box.right,
            lessThanOrEqualTo(editable.size.width),
            reason: '$id at scale $scale',
          );
        }
        expect(find.text(unit), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Windows keeps a hidden slider indicator inside its pane', (
    tester,
  ) async {
    var hidden = true;
    var value = 100.0;
    late StateSetter change;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              change = setState;
              return Offstage(
                offstage: hidden,
                child: NumericSlider(
                  id: 'latin-font-scale',
                  label: 'Latin font scale',
                  unit: '%',
                  value: value,
                  parameter: latinScaleParameter,
                  onChanged: (next) => setState(() => value = next),
                ),
              );
            },
          ),
        ),
      ),
    );
    final semantics = find.semantics.byFlag(SemanticsFlag.isSlider);
    expect(semantics, findsNothing);
    // The mounted value indicator must target an overlay below Offstage.
    // A route-level target would serialize an orphan on Windows.
    final portal = find.descendant(
      of: find.byType(Slider, skipOffstage: false),
      matching: find.byType(OverlayPortal, skipOffstage: false),
      skipOffstage: false,
    );
    final context = tester.element(portal);
    expect(
      Overlay.of(context),
      isNot(same(Overlay.of(context, rootOverlay: true))),
    );

    change(() => hidden = false);
    await tester.pumpAndSettle();
    expect(semantics, findsOne);
    tester.semantics.increase(semantics);
    await tester.pump();
    expect(value, greaterThan(100));
    tester.semantics.decrease(semantics);
    await tester.pump();
    expect(value, 100);
    // Tab through the number field to the slider.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, greaterThan(100));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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
          final scrollable = find
              .descendant(of: viewport, matching: find.byType(Scrollable))
              .first;
          final fontGroup = find.byKey(const PageStorageKey('settings-font'));
          await tester.scrollUntilVisible(
            fontGroup,
            180,
            scrollable: scrollable,
          );
          await tester.scrollUntilVisible(
            find.text(l.font),
            100,
            scrollable: scrollable,
          );
          // The first label must occupy space inside the scroll viewport.
          final fontLabel = find.text(l.font);
          expect(
            tester.getRect(fontLabel).top,
            greaterThanOrEqualTo(tester.getRect(viewport).top),
          );
          expect(
            tester.getRect(fontLabel).bottom,
            lessThan(
              tester
                  .getRect(find.byKey(const ValueKey('font-test.ttf-null')))
                  .top,
            ),
          );
          final layout = find.text(l.sizeSpacing);
          await tester.scrollUntilVisible(
            layout,
            200,
            scrollable: find
                .descendant(of: viewport, matching: find.byType(Scrollable))
                .first,
          );
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
