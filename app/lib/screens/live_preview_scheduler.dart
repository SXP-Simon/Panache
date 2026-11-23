import 'dart:async';

typedef LivePreviewDraft = ({int revision, int? previewRevision, bool full});

/// Debounces automatic previews. The editor supplies a draft only while
/// live submission is possible; the engine owns every job once submitted.
class LivePreviewScheduler {
  LivePreviewScheduler({required this.readDraft, required this.submit});

  final LivePreviewDraft? Function() readDraft;
  final void Function() submit;
  Timer? _pending;
  int? _submitted;
  bool _enabled = false;
  bool get enabled => _enabled;

  void setEnabled(bool enabled) {
    _enabled = enabled;
    _submitted = null;
    refresh();
  }

  /// Manual previews and fine editing can submit this same revision.
  void markSubmitted(int revision) => _submitted = revision;

  LivePreviewDraft? _nextDraft() {
    final draft = _enabled ? readDraft() : null;
    if (draft == null ||
        draft.previewRevision == draft.revision ||
        _submitted == draft.revision) {
      return null;
    }
    return draft;
  }

  void refresh() {
    _pending?.cancel();
    final draft = _nextDraft();
    if (draft == null) return;
    _pending = Timer(Duration(milliseconds: draft.full ? 750 : 350), () {
      // Locks and manual submissions may change during the debounce.
      if (_nextDraft()?.revision != draft.revision) return;
      _submitted = draft.revision;
      submit();
    });
  }

  void dispose() {
    _pending?.cancel();
  }
}
