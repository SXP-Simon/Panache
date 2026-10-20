import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

Future<void> configureUpdateProxy(HttpClient client, Uri uri) async {
  var proxy = HttpClient.findProxyFromEnvironment(uri);
  if (Platform.isAndroid) {
    try {
      proxy =
          await const MethodChannel('io.github.sxpsimon.panache/updates')
              .invokeMethod<String>('proxyForUrl', uri.toString()) ??
          proxy;
    } on PlatformException {
      /* Keep the environment fallback. */
    }
  }
  client.findProxy = (_) => proxy;
}

http.Client createUpdateHttpClient() => _ProxyClient();

class _ProxyClient extends http.BaseClient {
  final _raw = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  late final _client = IOClient(_raw);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await configureUpdateProxy(_raw, request.url);
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}
