import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'contract.dart';

TextPreparationJob startTextPreparation(
  String text, {
  String tableMode = 'latex',
  bool english = false,
  String? scriptUrl,
}) => _WebJob(text, tableMode, english, scriptUrl);

class _WebJob implements TextPreparationJob {
  final _result = Completer<String>();
  web.Worker? _worker;
  Timer? _timeout;
  _WebJob(String text, String mode, bool english, String? scriptUrl) {
    try {
      final worker = web.Worker(
        (scriptUrl ??
                Uri.parse(web.document.baseURI)
                    .resolve('prepare-text-worker.js')
                    .toString())
            .toJS,
      );
      _worker = worker;
      worker.onmessage = ((web.MessageEvent event) {
        final data = event.data.dartify();
        if (data is Map && data['result'] is String) {
          _finish(data['result'] as String);
        } else {
          _fail(StateError('Text preparation failed'));
        }
      }).toJS;
      worker.onerror = ((web.Event _) => _fail(
        StateError('Text worker failed to load'),
      )).toJS;
      worker.postMessage(
        {'text': text, 'tableMode': mode, 'english': english}.jsify(),
      );
      _timeout = Timer(
        const Duration(minutes: 2),
        () => _fail(TimeoutException('Text preparation timed out')),
      );
    } catch (error) {
      _fail(error);
    }
  }
  void _dispose() {
    _timeout?.cancel();
    _worker?.terminate();
    _worker = null;
  }

  void _finish(String text) {
    _dispose();
    if (!_result.isCompleted) _result.complete(text);
  }

  void _fail(Object error) {
    _dispose();
    if (!_result.isCompleted) _result.completeError(error);
  }

  @override
  Future<String> get result => _result.future;
  @override
  Future<void> cancel() async => _fail(const TextPreparationCancelled());
}
