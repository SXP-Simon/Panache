import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/engine_gateway.dart';

void main() {
  test('engine metadata tolerates older servers without capabilities', () {
    final legacy = EngineInfo.fromJson({'version': '1'});
    expect(legacy.version, '1');
    expect(legacy.canCancel, isFalse);
    final current = EngineInfo.fromJson({
      'version': '2',
      'capabilities': {'task_cancellation': true, 'task_submission_id': true},
    });
    expect(current.canCancel, isTrue);
    expect(current.canChooseTaskId, isTrue);
  });

  test('submission owns fields and upload bytes', () {
    final fields = {'text': 'submitted'};
    final bytes = Uint8List.fromList([1, 2]);
    final files = {'font_file': Upload('font.ttf', bytes)};
    final request = GenerationRequest(fields, files);
    fields['text'] = 'edited';
    bytes[0] = 9;
    files.clear();
    expect(request.fields['text'], 'submitted');
    expect(request.files['font_file']!.bytes, [1, 2]);
    expect(
      () => request.files['font_file']!.bytes[0] = 7,
      throwsUnsupportedError,
    );
  });

  test('HTTP and FFI task envelopes normalize to the same state', () {
    final http = EngineTask.fromJson({
      'status': 'success',
      'task_status': 'failed',
      'task_progress': 20,
      'task_stage': 'exporting',
      'pages_completed': 3,
      'error_code': 'invalid_font',
      'error_message': 'font missing',
    });
    final native = EngineTask.fromJson({
      'task_status': 'failed',
      'task_progress': 20,
      'task_stage': 'exporting',
      'pages_completed': 3,
      'error_code': 'invalid_font',
      'error_message': 'font missing',
    });
    expect(http.phase, native.phase);
    expect(http.errorCode, native.errorCode);
    expect(http.stage, native.stage);
    expect(http.pagesCompleted, 3);
    expect(http.pagesCompleted, native.pagesCompleted);
    expect(http.phase.terminal, isTrue);
    expect(TaskPhase.cancelling.terminal, isFalse);
    expect(EngineTask.fromJson({'status': 'error'}).phase, TaskPhase.failed);
    expect(
      () => EngineTask.fromJson({'status': 'success'}),
      throwsA(isA<ApiException>()),
    );
  });
}
