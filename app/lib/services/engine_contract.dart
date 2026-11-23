import 'dart:typed_data';

import '../models/engine_failure.dart';
import '../models/task_phase.dart';
import '../models/upload.dart';

export '../models/task_phase.dart';

/// Owns the submitted values, including upload bytes, across asynchronous work.
class GenerationRequest {
  GenerationRequest(Map<String, String> fields, Map<String, Upload> files)
    : fields = Map.unmodifiable(fields),
      files = Map.unmodifiable({
        for (final entry in files.entries)
          entry.key: Upload(
            entry.value.name,
            Uint8List.fromList(entry.value.bytes).asUnmodifiableView(),
          ),
      });

  final Map<String, String> fields;
  final Map<String, Upload> files;
}

class EngineTask {
  const EngineTask({
    required this.phase,
    required this.progress,
    this.stage,
    this.pagesCompleted = 0,
    this.errorCode,
    this.errorMessage,
  });

  final TaskPhase phase;
  final int progress, pagesCompleted;
  final String? stage, errorCode, errorMessage;

  factory EngineTask.fromJson(Map<String, dynamic> data) {
    final value = data['task_status'] ?? data['status'];
    final phase = TaskPhase.fromWire(value);
    if (phase == null) throw ApiException('Unknown task status: $value');
    return EngineTask(
      phase: phase,
      progress: ((data['task_progress'] ?? data['progress']) as num? ?? 0)
          .toInt()
          .clamp(0, 100),
      stage: data['task_stage'] as String?,
      pagesCompleted: ((data['pages_completed'] as num?) ?? 0).toInt().clamp(
        0,
        1000000,
      ),
      errorCode: data['error_code'] as String?,
      errorMessage: (data['error_message'] ?? data['message']) as String?,
    );
  }
}

class EngineInfo {
  const EngineInfo({
    required this.version,
    required this.canCancel,
    required this.canChooseTaskId,
    this.canFineEdit = false,
    this.canListLocalFonts = false,
  });
  final String version;
  final bool canCancel, canChooseTaskId;
  final bool canFineEdit, canListLocalFonts;
  factory EngineInfo.fromJson(Map<String, dynamic> value) {
    final capabilities = value['capabilities'];
    return EngineInfo(
      version: value['version'] as String? ?? '',
      canCancel:
          capabilities is Map && capabilities['task_cancellation'] == true,
      canChooseTaskId:
          capabilities is Map && capabilities['task_submission_id'] == true,
      canListLocalFonts:
          capabilities is Map && capabilities['local_fonts'] == true,
      canFineEdit: capabilities is Map && capabilities['fine_edit'] == true,
    );
  }
}

abstract interface class EngineCatalog {
  Future<List<String>> loadFonts();
  Future<EngineInfo> loadInfo();
}

/// Business operations do not expose HTTP responses or FFI paths.
abstract interface class EngineGateway {
  bool get supportsCancel;
  String? createTaskId();
  Future<String> submit(GenerationRequest request, {String? taskId});
  Future<EngineTask> status(String id);
  Future<List<Uint8List>> preview(String id);
  Future<Uint8List> export(String id);
  Future<void> cancel(String id);
}
