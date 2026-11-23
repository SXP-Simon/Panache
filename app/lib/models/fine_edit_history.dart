import 'fine_edit.dart';

/// Glyph adjustments for a rendered layout and the draft text that produced it.
class FineEditHistory {
  String? _text;
  FineEdits? _current;
  final _undo = <FineEdits?>[];
  final _redo = <FineEdits?>[];

  FineEdits? forText(String text) => _text == text ? _current : null;

  Map<int, FineAdjustment> adjustmentsFor(String key) =>
      _current?.key == key ? _current!.glyphs : const {};

  bool restore(String text, Map<String, dynamic> json) {
    try {
      _current = FineEdits.fromJson(json);
      _text = text;
      return true;
    } on FormatException {
      _current = null;
    } on TypeError {
      _current = null;
    }
    return false;
  }

  bool apply(String text, String key, List<FineAdjustment> changes) {
    final saved = forText(text);
    final previous = saved?.key == key ? saved : null;
    final next = <int, FineAdjustment>{...?previous?.glyphs};
    var changed = false;
    for (final value in changes) {
      if (value == defaultFineAdjustment(value.id)) {
        if (next.remove(value.id) != null) changed = true;
      } else if (next[value.id] != value) {
        next[value.id] = value;
        changed = true;
      }
    }
    if (!changed || next.length > FineEdits.maxGlyphs) return false;
    if (previous == null && _current != null) _undo.clear();
    if (_undo.length >= 50) _undo.removeAt(0);
    _undo.add(previous);
    _redo.clear();
    _text = text;
    _current = FineEdits(key, next);
    return true;
  }

  bool canStep(String text, String? key, {required bool redo}) =>
      key != null &&
      forText(text)?.key == key &&
      (redo ? _redo : _undo).isNotEmpty;

  bool step(String text, String? key, {required bool redo}) {
    if (!canStep(text, key, redo: redo)) return false;
    final from = redo ? _redo : _undo;
    final to = redo ? _undo : _redo;
    to.add(_current);
    _current = from.removeLast() ?? FineEdits(_current!.key, const {});
    return true;
  }
}
