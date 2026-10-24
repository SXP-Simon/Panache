import 'dart:async';
import 'dart:isolate';

import '../../utils/prepare_text.dart';
import 'contract.dart';

TextPreparationJob startTextPreparation(
  String text, {
  String tableMode = 'latex',
  bool english = false,
}) => _NativeJob(text, tableMode, english);

void _prepare((SendPort, String, String, bool) request) {
  final (port, text, mode, english) = request;
  try {
    port.send({
      'result': prepareHandwritingText(text, tableMode: mode, english: english),
    });
  } catch (_) {
    port.send({'error': true});
  }
}

class _NativeJob implements TextPreparationJob {
  final _result = Completer<String>();
  final _exit = Completer<void>();
  final _port = ReceivePort();
  late final Future<Isolate> _isolate;
  bool _cancelled = false;
  _NativeJob(String text, String mode, bool english) {
    _port.listen((dynamic message) {
      if (message == null) {
        if (!_exit.isCompleted) _exit.complete();
        _port.close();
        if (!_result.isCompleted) {
          _result.completeError(
            _cancelled
                ? const TextPreparationCancelled()
                : StateError('Text worker exited'),
          );
        }
      } else if (!_cancelled && !_result.isCompleted) {
        if (message is Map && message['result'] is String) {
          _result.complete(message['result'] as String);
        } else {
          _result.completeError(StateError('Text preparation failed'));
        }
      }
    });
    _isolate = Isolate.spawn(
      _prepare,
      (_port.sendPort, text, mode, english),
      onExit: _port.sendPort,
      onError: _port.sendPort,
      errorsAreFatal: true,
    );
    unawaited(
      _isolate
          .catchError((Object error, StackTrace stack) {
            _port.close();
            if (!_exit.isCompleted) _exit.complete();
            if (!_result.isCompleted) {
              _result.completeError(
                _cancelled ? const TextPreparationCancelled() : error,
                stack,
              );
            }
            throw error;
          })
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }
  @override
  Future<String> get result => _result.future;
  @override
  Future<void> cancel() async {
    if (_exit.isCompleted) return;
    _cancelled = true;
    try {
      final isolate = await _isolate;
      isolate.kill(priority: Isolate.immediate);
      await _exit.future;
    } catch (_) {
      // Spawn failure has already completed the result and exit futures.
    }
  }
}
