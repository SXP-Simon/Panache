import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../utils/prepare_text.dart';

@JS('self')
external web.DedicatedWorkerGlobalScope get workerScope;

void main() {
  workerScope.onmessage = ((web.MessageEvent event) {
    final input = event.data.dartify() as Map;
    try {
      final result = prepareHandwritingText(
        input['text'] as String,
        tableMode: input['tableMode'] as String? ?? 'latex',
        english: input['english'] == true,
      );
      workerScope.postMessage({'result': result}.jsify());
    } catch (_) {
      workerScope.postMessage({'error': true}.jsify());
    }
  }).toJS;
}
