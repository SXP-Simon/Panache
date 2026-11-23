import 'dart:typed_data';

import 'api.dart';
import 'engine_contract.dart';

export 'engine_contract.dart';

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
    return EngineInfo.fromJson(value);
  }

  void configure(EngineInfo info) => api.configureCapabilities({
    'capabilities': {
      'task_cancellation': info.canCancel,
      'task_submission_id': info.canChooseTaskId,
      'fine_edit': info.canFineEdit,
      'local_fonts': info.canListLocalFonts,
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
