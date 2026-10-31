import 'dart:typed_data';

import 'api.dart';

enum TaskPhase {
  pending,
  processing,
  cancelling,
  completed,
  failed,
  cancelled;

  bool get terminal => this == completed || this == failed || this == cancelled;
}

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
    final phase = value == 'error'
        ? TaskPhase.failed
        : TaskPhase.values.where((phase) => phase.name == value).firstOrNull;
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
  });
  final String version;
  final bool canCancel, canChooseTaskId;
  factory EngineInfo.fromJson(Map<String, dynamic> value) {
    final capabilities = value['capabilities'];
    return EngineInfo(
      version: value['version'] as String? ?? '',
      canCancel:
          capabilities is Map && capabilities['task_cancellation'] == true,
      canChooseTaskId:
          capabilities is Map && capabilities['task_submission_id'] == true,
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

/// Migration adapter for both existing HTTP and mobile transports.
class ApiEngineGateway implements EngineGateway, EngineCatalog {
  ApiEngineGateway(this.api);
  final HandwritingApi api;

  @override
  Future<List<String>> loadFonts() async =>
      List<String>.unmodifiable(await api.getJson('/api/fonts_info') as List);
  @override
  Future<EngineInfo> loadInfo() async {
    final value = Map<String, dynamic>.from(
      await api.getJson('/api/version') as Map,
    );
    final info = EngineInfo.fromJson(value);
    return info;
  }

  void configure(EngineInfo info) => api.configureCapabilities({
    'capabilities': {
      'task_cancellation': info.canCancel,
      'task_submission_id': info.canChooseTaskId,
    },
  });

  @override
  bool get supportsCancel => api.supportsCancel;
  @override
  String? createTaskId() => api.createTaskId();
  @override
  Future<String> submit(GenerationRequest request, {String? taskId}) =>
      api.submit(request.fields, request.files, taskId: taskId);
  @override
  Future<EngineTask> status(String id) async =>
      EngineTask.fromJson(await api.status(id));
  @override
  Future<List<Uint8List>> preview(String id) => api.preview(id);
  @override
  Future<Uint8List> export(String id) async => (await api.result(id)).bodyBytes;
  @override
  Future<void> cancel(String id) => api.cancelTask(id);
}
