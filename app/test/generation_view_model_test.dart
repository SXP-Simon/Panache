import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/engine_gateway.dart';
import 'package:handwriting_app/view_models/generation_view_model.dart';
import 'package:handwriting_app/models/engine_failure.dart';

class ControlledEngine implements EngineGateway {
  final submitted = Completer<String>();
  final exited = Completer<void>();
  final cancelled = <String>[];
  bool failIdentity = false;
  @override
  bool get supportsCancel => true;
  @override
  String? createTaskId() {
    if (failIdentity) throw StateError('identity unavailable');
    return null;
  }

  @override
  Future<String> submit(GenerationRequest request, {String? taskId}) =>
      submitted.future;
  @override
  Future<void> cancel(String id) {
    cancelled.add(id);
    return exited.future;
  }

  @override
  Future<EngineTask> status(String id) async =>
      const EngineTask(phase: TaskPhase.completed, progress: 100);
  @override
  Future<List<Uint8List>> preview(String id) async => [
    Uint8List.fromList([1]),
  ];
  @override
  Future<Uint8List> export(String id) async => Uint8List.fromList([2]);
}

void main() {
  test(
    'queue failures preserve code and retry delay without parsing text',
    () async {
      final model = GenerationViewModel();
      final engine = ControlledEngine();
      final pending = model.generate(
        GenerationRequest({'text': 'draft'}, {}),
        engine,
        revision: 1,
        preview: true,
        pdf: false,
      );
      engine.submitted.completeError(
        const EngineFailure('busy', code: 'queue_full', retryAfterSeconds: 30),
      );
      expect(await pending, isFalse);
      expect(model.error, 'busy');
      expect(model.errorCode, 'queue_full');
      expect(model.queueWaitSeconds, 30);
      expect(model.busy, isFalse);
      expect(model.available, isFalse);
      model.dispose();
    },
  );

  test(
    'shutdown waits for late submission and confirmed exit before closing',
    () async {
      final model = GenerationViewModel();
      final engine = ControlledEngine();
      final pending = model.generate(
        GenerationRequest({'text': 'draft'}, {}),
        engine,
        revision: 7,
        preview: true,
        pdf: false,
      );
      var closed = false;
      model.shutdown(() => closed = true);
      expect(closed, isFalse);
      engine.submitted.complete('late');
      expect(await pending, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(engine.cancelled, ['late']);
      expect(closed, isFalse);
      engine.exited.complete();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isTrue);
      expect(model.pages, isEmpty);
    },
  );

  test('identity failure releases the task slot for retry', () async {
    final model = GenerationViewModel();
    final engine = ControlledEngine()..failIdentity = true;
    final request = GenerationRequest({'text': 'draft'}, {});
    expect(
      await model.generate(
        request,
        engine,
        revision: 1,
        preview: true,
        pdf: false,
      ),
      isFalse,
    );
    expect(model.available, isTrue);
    engine.failIdentity = false;
    engine.submitted.complete('retry');
    expect(
      await model.generate(
        request,
        engine,
        revision: 2,
        preview: true,
        pdf: false,
      ),
      isTrue,
    );
    expect(model.previewRevision, 2);
    expect(model.previewTaskId, 'retry');
    model.dispose();
  });
}
