import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/fine_edit.dart';
import 'package:handwriting_app/view_models/fine_selection.dart';
import 'package:handwriting_app/view_models/fine_selection_drag.dart';

void main() {
  final page = FinePage('layout', Uint8List(0), const [
    FineGlyph(7, 0, 0, 20, 20, 0, 0, 20, null),
  ]);
  test('only the owning mouse crosses screen slop to move a new hit', () {
    final selection = FineSelection();
    final drag = FineSelectionDrag.begin(
      selection,
      page,
      const {},
      pointer: 3,
      start: const Offset(10, 10),
      screen: const Offset(240, 90),
      touch: false,
      shift: false,
    );
    expect(drag.action, FineDragAction.move);
    expect(drag.acceptsMove(5, const Offset(300, 90)), isFalse);
    expect(drag.acceptsMove(3, const Offset(243.9, 90)), isFalse);
    expect(drag.acceptsMove(3, const Offset(244, 90)), isTrue);
    expect(drag.selectMoveTarget(selection, mouse: true), isTrue);
    expect(selection.selected, {7});
  });

  test('touch tap selects but a drag in tap mode leaves selection intact', () {
    final selection = FineSelection();
    final drag = FineSelectionDrag.begin(
      selection,
      page,
      const {},
      pointer: 1,
      start: const Offset(10, 10),
      screen: Offset.zero,
      touch: true,
      shift: true,
    );
    expect(drag.action, FineDragAction.tap);
    expect(
      drag.finishSelection(
        selection,
        page,
        const {},
        Offset.zero,
        mouse: false,
      ),
      isTrue,
    );
    expect(selection.selected, {7});
    selection.select([]);
    drag.moved = true;
    expect(
      drag.finishSelection(
        selection,
        page,
        const {},
        Offset.zero,
        mouse: false,
      ),
      isFalse,
    );
    expect(selection.selected, isEmpty);
  });

  test(
    'perspective handle hit includes the radius and prefers the later tie',
    () {
      final frame = FinePerspectiveFrame(const [
        Offset(0, 0),
        Offset(10, 0),
      ], {});
      final touch = FineCornerDrag.hit(1, const Offset(5, 0), frame, 5);
      expect(touch?.index, 1);
      expect(FineCornerDrag.hit(1, const Offset(5, 0), frame, 4.9), isNull);
    },
  );
}
