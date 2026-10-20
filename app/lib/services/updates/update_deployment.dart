import 'dart:convert';

import 'package:http/http.dart' as http;

import 'update_model.dart';

Uri deployedVersionUri(Uri base, Uri current) {
  if (base.origin != current.origin ||
      !{'http', 'https'}.contains(base.scheme)) {
    throw const UpdateException(UpdateProblem.invalidResponse);
  }
  return base
      .resolve('version.json')
      .replace(
        queryParameters: {
          'panache_update': DateTime.now().microsecondsSinceEpoch.toString(),
        },
      );
}

Future<DeployedApp> loadDeployedVersion(http.Client client, Uri uri) async {
  try {
    final request = http.Request('GET', uri)
      ..headers['Cache-Control'] = 'no-cache';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const UpdateException(UpdateProblem.network);
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) {
        throw const UpdateException(UpdateProblem.invalidResponse);
      }
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        data['version'] is! String ||
        parseAppVersion(data['version'] as String) == null) {
      throw const UpdateException(UpdateProblem.invalidResponse);
    }
    return DeployedApp(
      data['version'] as String,
      data['build_id'] is String ? data['build_id'] as String : '',
    );
  } on UpdateException {
    rethrow;
  } on FormatException {
    throw const UpdateException(UpdateProblem.invalidResponse);
  } catch (_) {
    throw const UpdateException(UpdateProblem.network);
  }
}
