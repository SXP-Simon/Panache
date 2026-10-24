import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

class Upload {
  const Upload(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

class ApiException implements Exception {
  ApiException(this.message, {this.status, this.waitSeconds});
  final String message;
  final int? status, waitSeconds;
  @override
  String toString() => message;
}

class HandwritingApi {
  HandwritingApi(this.base, {http.Client? client, String? accessToken})
    : accessToken =
          accessToken ??
          (kIsWeb
              ? ''
              : const String.fromEnvironment('HANDWRITING_ACCESS_TOKEN')),
      client = client ?? http.Client();
  final String base;
  final String accessToken;
  Map<String, String> get headers =>
      accessToken.isEmpty ? const {} : {'Authorization': 'Bearer $accessToken'};
  final http.Client client;
  Uri uri(String path) => Uri.parse('$base$path');

  Future<http.Response> checked(Future<http.Response> future) async {
    final response = await future.timeout(const Duration(seconds: 90));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        /* Non-JSON HTTP error. */
      }
      throw ApiException(
        data is Map
            ? '${data['message'] ?? data['error'] ?? data['detail'] ?? response.statusCode}'
            : 'HTTP ${response.statusCode}',
        status: response.statusCode,
        waitSeconds: data is Map
            ? data['estimated_wait_seconds'] as int?
            : null,
      );
    }
    return response;
  }

  Future<dynamic> getJson(String path) async => jsonDecode(
    utf8.decode(
      (await checked(client.get(uri(path), headers: headers))).bodyBytes,
    ),
  );

  Future<http.Response> multipart(
    String path,
    Map<String, String> fields,
    Map<String, Upload> files, {
    String? taskId,
  }) async {
    final request = http.MultipartRequest('POST', uri(path))
      ..fields.addAll(fields)
      ..headers.addAll(headers);
    if (taskId != null) request.headers['X-Panache-Task-Id'] = taskId;
    for (final entry in files.entries) {
      request.files.add(
        http.MultipartFile.fromBytes(
          entry.key,
          entry.value.bytes,
          filename: entry.value.name,
        ),
      );
    }
    return checked(client.send(request).then(http.Response.fromStream));
  }

  Future<Map<String, dynamic>> importFile(String path, Upload file) async {
    final response = await multipart(path, {}, {'file': file});
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<String> submit(
    Map<String, String> fields,
    Map<String, Upload> files, {
    String? taskId,
  }) async {
    final response = await multipart(
      '/api/generate_handwriting',
      fields,
      files,
      taskId: taskId,
    );
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    if (data['task_id'] is! String) throw ApiException('Missing task_id');
    if (taskId != null && data['task_id'] != taskId) {
      throw ApiException('Task identity mismatch');
    }
    return data['task_id'];
  }

  Future<Map<String, dynamic>> status(String id) async =>
      (await getJson('/api/generate_handwriting/task/$id'))
          as Map<String, dynamic>;
  Future<http.Response> result(String id) => checked(
    client.get(
      uri('/api/generate_handwriting/task/$id/result'),
      headers: headers,
    ),
  );
  bool _supportsCancel = false;
  bool _supportsSubmissionId = false;
  String? createTaskId() {
    if (!_supportsSubmissionId) return null;
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  bool get supportsCancel => _supportsCancel;
  void configureCapabilities(dynamic info) {
    _supportsCancel =
        info is Map &&
        info['capabilities'] is Map &&
        info['capabilities']['task_cancellation'] == true;
    _supportsSubmissionId =
        _supportsCancel && info['capabilities']['task_submission_id'] == true;
  }

  Future<void> cancelTask(String id) async {
    if (!supportsCancel) throw UnsupportedError('Cancellation unavailable');
    await checked(
      client.post(
        uri('/api/generate_handwriting/task/$id/cancel'),
        headers: headers,
      ),
    );
    await waitForTaskExit(id);
  }

  /// A cancellation acknowledgement is not proof that the renderer has exited.
  Future<void> waitForTaskExit(String id) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (true) {
      final data = await status(id);
      final phase = data['task_status'] ?? data['status'];
      if (['completed', 'failed', 'error', 'cancelled'].contains(phase)) return;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Task cancellation has not been confirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<List<Uint8List>> preview(String id) async {
    final response = await result(id);
    if (response.headers['content-type']?.contains('json') ?? false) {
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      return [
        for (final image in data['images'] as List)
          base64Decode(image as String),
      ];
    }
    return [response.bodyBytes];
  }

  void close() => client.close();
}
