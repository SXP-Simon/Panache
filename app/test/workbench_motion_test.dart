import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/widgets/appearance_transition.dart';
import 'package:handwriting_app/widgets/workbench_motion.dart';

void main() {
  testWidgets(
    'appearance transitions keep input live and discard stale frames',
    (tester) async {
      var dark = false;
      var reduced = false;
      var taps = 0;
      late StateSetter update;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AppearanceTransition(
              appearance: (
                dark ? Brightness.dark : Brightness.light,
                Colors.teal,
                Colors.purple,
              ),
              reduceMotion: reduced,
              child: GestureDetector(
                onTap: () => taps++,
                child: ColoredBox(color: dark ? Colors.black : Colors.white),
              ),
            );
          },
        ),
      );
      update(() => dark = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(RawImage), findsOneWidget);
      await tester.tap(find.byType(GestureDetector));
      expect(taps, 1);
      update(() => dark = false);
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(780, 600);
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      update(() {
        reduced = true;
        dark = true;
      });
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

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

  testWidgets(
    'third destination continues visible layers and receives sole input',
    (tester) async {
      var selected = 0;
      var reduced = false;
      final taps = <int>[];
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQueryData(disableAnimations: reduced),
                child: RetainedPaneSwitcher(
                  index: selected,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Center(
                        child: TextButton(
                          onPressed: () => taps.add(i),
                          child: Text('pane $i'),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      update(() => selected = 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final departing = tester.getCenter(find.text('pane 0'));
      final passing = tester.getCenter(find.text('pane 1'));
      update(() => selected = 2);
      await tester.pump();
      expect(tester.getCenter(find.text('pane 0')), departing);
      expect(tester.getCenter(find.text('pane 1')), passing);
      // A live change in accessibility preferences also cancels pending exits.
      update(() => reduced = true);
      await tester.pump();
      expect(find.text('pane 0'), findsNothing);
      expect(find.text('pane 1'), findsNothing);
      await tester.tap(find.text('pane 2'));
      expect(taps, [2]);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

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
