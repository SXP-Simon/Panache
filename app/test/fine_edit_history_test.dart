import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/fine_edit.dart';
import 'package:handwriting_app/models/fine_edit_history.dart';

FineAdjustment moved(int id, int dx) => (
  id: id,
  dx: dx,
  dy: 0,
  scale: 100,
  angle: 0,
  opacity: 100,
  color: null,
  thickness: 0,
  softness: 0,
  warp: null,
);

void main() {
  test('history follows the source text and rendered layout', () {
    final history = FineEditHistory();
    final key = 'a' * 64;
    final newKey = 'b' * 64;
    final first = moved(1, 4);
    expect(history.apply('draft', key, [first]), isTrue);
    expect(history.apply('draft', key, [first]), isFalse);
    expect(history.forText('revised'), isNull);
    expect(history.adjustmentsFor(key), {1: first});
    expect(history.adjustmentsFor(newKey), isEmpty);
    expect(history.step('revised', key, redo: false), isFalse);
    expect(history.step('draft', newKey, redo: false), isFalse);
    expect(history.step('draft', key, redo: false), isTrue);
    expect(history.forText('draft')!.glyphs, isEmpty);
    expect(history.canStep('draft', key, redo: false), isFalse);
    expect(history.step('draft', key, redo: true), isTrue);
    expect(history.adjustmentsFor(key), {1: first});

    final second = moved(2, 8);
    expect(history.apply('revised', newKey, [second]), isTrue);
    expect(history.adjustmentsFor(newKey), {2: second});
    expect(history.step('revised', newKey, redo: false), isTrue);
    expect(history.adjustmentsFor(newKey), isEmpty);
    expect(history.canStep('revised', newKey, redo: false), isFalse);
    expect(history.apply('revised', newKey, [first]), isTrue);
    expect(history.canStep('revised', newKey, redo: true), isFalse);
  });

  test('history bounds reject the whole oversized edit and preserve redo', () {
    final history = FineEditHistory();
    final key = 'a' * 64;
    for (var i = 1; i <= 51; i++) {
      history.apply('draft', key, [moved(1, i)]);
    }
    for (var i = 0; i < 50; i++) {
      expect(history.step('draft', key, redo: false), isTrue);
    }
    expect(history.step('draft', key, redo: false), isFalse);
    expect(history.adjustmentsFor(key), {1: moved(1, 1)});
    final oversized = [for (var i = 0; i <= 10000; i++) moved(i, 7)];
    expect(history.apply('draft', key, oversized), isFalse);
    expect(history.step('draft', key, redo: true), isTrue);
    expect(history.adjustmentsFor(key), {1: moved(1, 2)});
  });
}
