import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/engine_failure.dart';
import '../models/ink_page.dart';
import '../services/engine_contract.dart';

class _GenerationOperation {
  _GenerationOperation(this.engine);
  final EngineGateway engine;
  final _submitted = Completer<String?>();
  bool cancelled = false;
  Future<void>? stopping;

  // Both user cancellation and shutdown must wait for the original engine's
  // identity. A locally reserved ID is usable before submission completes.
  void resolveId(String? id) {
    if (!_submitted.isCompleted) _submitted.complete(id);
  }

  Future<String?> get id => _submitted.future;
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
  List<InkPage?> inkPages = [];
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
    bool Function()? acceptPreview,
  }) async {
    if (!available) return false;
    final generation = ++_generation;
    final operation = _GenerationOperation(engine);
    _operation = operation;
    bool current() =>
        !disposed && generation == _generation && !operation.cancelled;
    var succeeded = false;
    _begin();
    try {
      final requestedId = engine.createTaskId();
      if (requestedId != null) {
        taskId = requestedId;
        operation.resolveId(requestedId);
      }
      final submittedId = await engine.submit(request, taskId: requestedId);
      operation.resolveId(submittedId);
      if (!current()) return false;
      taskId = submittedId;
      await onSubmitted?.call();
      if (!current()) return false;
      final deadline = DateTime.now().add(const Duration(minutes: 29));
      while (current()) {
        final task = await engine.status(submittedId);
        if (!current()) return false;
        if (_publishStatus(task, deadline)) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (!current()) return false;
      if (preview) {
        if (acceptPreview?.call() == false) return false;
        final rendered = await engine.preview(submittedId);
        if (!current() || acceptPreview?.call() == false) return false;
        _publishPreview(
          rendered,
          submittedId,
          revision,
          keepPage: acceptPreview != null,
        );
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
      _publishFailure(e);
    } catch (e) {
      if (!current()) return false;
      error = '$e';
    } finally {
      operation.resolveId(null);
      if (!succeeded && current() && _needsStop(engine)) {
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

  void _begin() {
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
  }

  bool _publishStatus(EngineTask task, DateTime deadline) {
    phase = task.phase.name;
    progress = task.progress;
    stage = task.stage ?? '';
    pagesCompleted = task.pagesCompleted;
    emit();
    if (task.phase == TaskPhase.failed || task.phase == TaskPhase.cancelled) {
      throw EngineFailure(
        task.errorMessage ?? 'Task failed',
        code: task.errorCode,
      );
    }
    if (task.phase == TaskPhase.completed) return true;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Task timed out');
    }
    return false;
  }

  void _publishPreview(
    List<Uint8List> rendered,
    String id,
    int revision, {
    required bool keepPage,
  }) {
    inkPages = rendered.map(InkPage.fromPacket).toList(growable: false);
    pages = [
      for (var i = 0; i < rendered.length; i++)
        inkPages[i]?.paper ?? rendered[i],
    ];
    previewRevision = revision;
    previewTaskId = id;
    page = !keepPage || pages.isEmpty ? 0 : page.clamp(0, pages.length - 1);
  }

  void _publishFailure(EngineFailure e) {
    error = e.message;
    errorCode = e.code;
    queueWaitSeconds = e.retryAfterSeconds;
    if (e.retryAfterSeconds != null) {
      retryAt = DateTime.now().add(Duration(seconds: e.retryAfterSeconds!));
    }
  }

  bool _needsStop(EngineGateway engine) =>
      taskId.isNotEmpty &&
      engine.supportsCancel &&
      TaskPhase.fromWire(phase)?.terminal != true;

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
        final id = await operation.id;
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
          final id = await operation.id;
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
