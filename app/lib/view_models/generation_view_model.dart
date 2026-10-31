import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/engine_failure.dart';
import '../services/engine_gateway.dart';

class _GenerationOperation {
  _GenerationOperation(this.engine);
  final EngineGateway engine;
  final submitted = Completer<String?>();
  bool cancelled = false;
  Future<void>? stopping;
}

/// Task state owns engine operations; it has no navigation or editor controllers.
class GenerationViewModel extends ChangeNotifier {
  bool disposed = false, busy = false;
  String phase = '', stage = '', error = '', taskId = '';
  int pagesCompleted = 0;
  String? errorCode;
  int? queueWaitSeconds;
  int progress = 0, page = 0;
  DateTime? retryAt;
  List<Uint8List> pages = [];
  Uint8List? exportBytes;
  String exportExtension = '';
  int? previewRevision;
  String? previewTaskId;
  int _generation = 0;
  _GenerationOperation? _operation;
  bool get stopping => _operation?.stopping != null;
  bool get available =>
      !disposed &&
      !busy &&
      (retryAt == null || !DateTime.now().isBefore(retryAt!));

  Future<bool> generate(
    GenerationRequest request,
    EngineGateway engine, {
    required int revision,
    required bool preview,
    required bool pdf,
    Future<void> Function()? onSubmitted,
  }) async {
    if (!available) return false;
    final generation = ++_generation;
    final operation = _GenerationOperation(engine);
    _operation = operation;
    bool current() =>
        !disposed && generation == _generation && !operation.cancelled;
    var succeeded = false;
    busy = true;
    taskId = '';
    error = '';
    errorCode = null;
    queueWaitSeconds = null;
    progress = 0;
    phase = 'pending';
    stage = 'preparing';
    pagesCompleted = 0;
    emit();
    try {
      final requestedId = engine.createTaskId();
      if (requestedId != null) {
        taskId = requestedId;
        operation.submitted.complete(requestedId);
      }
      final submittedId = await engine.submit(request, taskId: requestedId);
      if (!operation.submitted.isCompleted) {
        operation.submitted.complete(submittedId);
      }
      if (!current()) return false;
      taskId = submittedId;
      await onSubmitted?.call();
      if (!current()) return false;
      final deadline = DateTime.now().add(const Duration(minutes: 29));
      while (current()) {
        final task = await engine.status(submittedId);
        if (!current()) return false;
        phase = task.phase.name;
        progress = task.progress;
        stage = task.stage ?? '';
        pagesCompleted = task.pagesCompleted;
        emit();
        if (task.phase == TaskPhase.failed ||
            task.phase == TaskPhase.cancelled) {
          throw EngineFailure(
            task.errorMessage ?? 'Task failed',
            code: task.errorCode,
          );
        }
        if (task.phase == TaskPhase.completed) break;
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Task timed out');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (!current()) return false;
      if (preview) {
        final rendered = await engine.preview(submittedId);
        if (!current()) return false;
        pages = rendered;
        previewRevision = revision;
        previewTaskId = submittedId;
        page = 0;
      } else {
        final bytes = await engine.export(submittedId);
        if (!current()) return false;
        exportBytes = bytes;
        exportExtension = pdf ? 'pdf' : 'zip';
      }
      progress = 100;
      succeeded = true;
    } on EngineFailure catch (e) {
      if (!current()) return false;
      error = e.message;
      errorCode = e.code;
      queueWaitSeconds = e.retryAfterSeconds;
      if (e.retryAfterSeconds != null) {
        retryAt = DateTime.now().add(Duration(seconds: e.retryAfterSeconds!));
      }
    } catch (e) {
      if (!current()) return false;
      error = '$e';
    } finally {
      if (!operation.submitted.isCompleted) operation.submitted.complete(null);
      if (!succeeded &&
          current() &&
          taskId.isNotEmpty &&
          engine.supportsCancel &&
          !['completed', 'failed', 'error', 'cancelled'].contains(phase)) {
        final failure = error;
        await cancel();
        if (!disposed && !busy) {
          error = failure;
          emit();
        }
      }
      if (current()) {
        busy = false;
        _operation = null;
        emit();
      }
    }
    return current() && succeeded;
  }

  Future<void> cancel() {
    final operation = _operation;
    if (!busy ||
        disposed ||
        operation == null ||
        !operation.engine.supportsCancel) {
      return Future.value();
    }
    if (operation.stopping != null) return operation.stopping!;
    operation.cancelled = true;
    phase = 'cancelling';
    error = '';
    final stopped = () async {
      try {
        final id = await operation.submitted.future;
        if (id != null) await operation.engine.cancel(id);
        if (disposed || !identical(operation, _operation)) return;
        ++_generation;
        busy = false;
        phase = 'cancelled';
        _operation = null;
      } catch (e) {
        if (disposed || !identical(operation, _operation)) return;
        // Keep the slot locked until termination is confirmed; retry is safe.
        error = '$e';
      } finally {
        operation.stopping = null;
        emit();
      }
    }();
    operation.stopping = stopped;
    emit();
    return stopped;
  }

  void emit() {
    if (!disposed) notifyListeners();
  }

  /// The transport stays alive until a submitted worker has confirmed exit.
  void shutdown(VoidCallback closeTransport) {
    final operation = _operation;
    dispose();
    if (operation != null && operation.engine.supportsCancel) {
      operation.cancelled = true;
      unawaited(() async {
        try {
          final id = await operation.submitted.future;
          if (id != null) await operation.engine.cancel(id);
        } catch (_) {
          // Shutdown cannot publish a new UI error.
        } finally {
          closeTransport();
        }
      }());
    } else {
      closeTransport();
    }
  }

  @override
  void dispose() {
    ++_generation;
    disposed = true;
    pages = [];
    exportBytes = null;
    super.dispose();
  }
}
