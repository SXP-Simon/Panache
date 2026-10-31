import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/widgets/workbench_motion.dart';

void main() {
  testWidgets('pane motion preserves the editor and retracts on reversal', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'draft');
    addTearDown(controller.dispose);
    var selected = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return RetainedPaneSwitcher(
              index: selected,
              children: [
                Material(
                  child: TextField(
                    key: const ValueKey('retained-editor'),
                    controller: controller,
                  ),
                ),
                const Center(child: Text('Paper')),
                const Center(child: Text('Preview')),
              ],
            );
          },
        ),
      ),
    );
    final editor = find.byKey(const ValueKey('retained-editor'));
    final element = tester.element(editor);
    await tester.enterText(editor, 'draft after editing');
    update(() => selected = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final paper = find.text('Paper');
    final before = tester.getTopLeft(paper);
    update(() => selected = 0);
    await tester.pump();
    expect(tester.getTopLeft(paper), before);
    await tester.pumpAndSettle();
    expect(tester.element(editor), same(element));
    expect(controller.text, 'draft after editing');
    for (final index in [2, 1, 0]) {
      update(() => selected = index);
      await tester.pump(const Duration(milliseconds: 35));
    }
    await tester.pumpAndSettle();
    expect(tester.element(editor), same(element));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outgoing panes cannot receive taps while still painted', (
    tester,
  ) async {
    var selected = 0, oldTaps = 0, newTaps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return RetainedPaneSwitcher(
              index: selected,
              children: [
                Center(
                  child: TextButton(
                    onPressed: () => oldTaps++,
                    child: const Text('Old'),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: () => newTaps++,
                    child: const Text('New'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    final position = tester.getCenter(find.text('Old'));
    update(() => selected = 1);
    await tester.pump();
    await tester.tapAt(position);
    expect(oldTaps, 0);
    expect(newTaps, 0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New'));
    expect(newTaps, 1);
  });

  testWidgets('reduced motion selects immediately without replacing children', (
    tester,
  ) async {
    var selected = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return RetainedPaneSwitcher(
                index: selected,
                children: const [Text('Editor'), Text('Preview')],
              );
            },
          ),
        ),
      ),
    );
    update(() => selected = 1);
    await tester.pump();
    expect(find.text('Editor'), findsNothing);
    expect(find.text('Preview'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
