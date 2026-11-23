import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/fine_edit.dart';
import 'package:handwriting_app/view_models/fine_selection.dart';

void main() {
  test(
    'source selection uses overlaps and preserves picks on unmapped pages',
    () {
      const first = FineGlyph(5, 0, 0, 8, 8, 0, 0, 8, (start: 0, end: 3), 5);
      const detail = FineGlyph(9, 8, 0, 8, 8, 8, 0, 8, null, 5);
      const next = FineGlyph(3, 16, 0, 8, 8, 16, 0, 8, (start: 3, end: 4));
      final page = FinePage('page', Uint8List(0), [first, detail, next]);
      final selection = FineSelection()..selectIllustration(page, 5);
      expect(selection.selected.toList(), [5, 9]);

      selection.selectSource(FinePage('unmapped', Uint8List(0), [detail]), (
        start: 3,
        end: 4,
      ));
      expect(selection.selected.toList(), [5, 9]);
      selection.selectSource(page, (start: 3, end: 4));
      expect(selection.selected.toList(), [3]);
      selection.selectSource(page, (start: 2, end: 4));
      expect(selection.selected.toList(), [5, 3]);
      selection.selectSource(page, (start: 4, end: 5));
      expect(selection.selected, isEmpty);
    },
  );

  test('selection adjustments keep each glyph geometry and untouched ink', () {
    const previous = (
      id: 7,
      dx: 2,
      dy: -1,
      scale: 125,
      angle: 7,
      opacity: 42,
      color: 0xff336699,
      thickness: 1,
      softness: 2,
      warp: (1.0, 0.1, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0),
    );
    final edits = <int, FineAdjustment>{
      7: previous,
      8: defaultFineAdjustment(8),
    };
    final selection = FineSelection()..select([9, 7]);
    final changed = selection.adjust(edits, opacity: 0, thickness: -2);
    expect(changed.map((edit) => edit.id), [9, 7]);
    expect(changed.first, (
      id: 9,
      dx: 0,
      dy: 0,
      scale: 100,
      angle: 0,
      opacity: 0,
      color: null,
      thickness: -2,
      softness: 0,
      warp: null,
    ));
    expect(changed.last, (
      id: 7,
      dx: 2,
      dy: -1,
      scale: 125,
      angle: 7,
      opacity: 0,
      color: 0xff336699,
      thickness: -2,
      softness: 2,
      warp: previous.warp,
    ));
    expect(edits, {7: previous, 8: defaultFineAdjustment(8)});
  });
}
