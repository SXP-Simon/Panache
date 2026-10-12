import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
  HandwritingApi(this.base, {http.Client? client})
    : client = client ?? http.Client();
  final String base;
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

  Future<dynamic> getJson(String path) async =>
      jsonDecode(utf8.decode((await checked(client.get(uri(path)))).bodyBytes));

  Future<http.Response> multipart(
    String path,
    Map<String, String> fields,
    Map<String, Upload> files,
  ) async {
    final request = http.MultipartRequest('POST', uri(path))
      ..fields.addAll(fields);
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
    Map<String, Upload> files,
  ) async {
    final response = await multipart(
      '/api/generate_handwriting',
      fields,
      files,
    );
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    if (data['task_id'] is! String) throw ApiException('Missing task_id');
    return data['task_id'];
  }

  Future<Map<String, dynamic>> status(String id) async =>
      (await getJson('/api/generate_handwriting/task/$id'))
          as Map<String, dynamic>;
  Future<http.Response> result(String id) =>
      checked(client.get(uri('/api/generate_handwriting/task/$id/result')));
  void close() => client.close();
}
