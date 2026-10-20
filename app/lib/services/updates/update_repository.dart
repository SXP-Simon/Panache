import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'update_model.dart';
import 'update_http.dart';

class UpdateRepository {
  UpdateRepository({http.Client? client})
    : client = client ?? createUpdateHttpClient();
  final http.Client client;
  void close() => client.close();

  Future<Map<String, dynamic>> _json(Uri uri, [int redirects = 0]) async {
    try {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['Accept'] = 'application/vnd.github+json';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 403 || response.statusCode == 429) {
        await response.stream.listen(null).cancel();
        throw const UpdateException(UpdateProblem.rateLimited);
      }
      // Release download URLs redirect to GitHub's own asset storage.
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        await response.stream.drain<void>().timeout(
          const Duration(seconds: 20),
        );
        final location = response.headers['location'];
        if (location == null) {
          throw const UpdateException(UpdateProblem.invalidResponse);
        }
        final target = uri.resolve(location);
        if (redirects >= 5 ||
            target.scheme != 'https' ||
            target.hasPort ||
            target.userInfo.isNotEmpty ||
            !{
              'release-assets.githubusercontent.com',
              'objects.githubusercontent.com',
            }.contains(target.host)) {
          throw const UpdateException(UpdateProblem.invalidResponse);
        }
        return await _json(target, redirects + 1);
      }
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw const UpdateException(UpdateProblem.network);
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const UpdateException(UpdateProblem.invalidResponse);
        }
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) {
        throw const UpdateException(UpdateProblem.invalidResponse);
      }
      return value;
    } on UpdateException {
      rethrow;
    } on FormatException {
      throw const UpdateException(UpdateProblem.invalidResponse);
    } catch (_) {
      throw const UpdateException(UpdateProblem.network);
    }
  }

  Future<AppRelease> latest() async {
    final data = await _json(
      Uri.https('api.github.com', '/repos/$releaseRepository/releases/latest'),
    );
    final raw = data['tag_name'];
    final version = raw is String ? parseAppVersion(raw) : null;
    final assets = data['assets'];
    if (version == null ||
        version.isPreRelease ||
        data['draft'] != false ||
        data['prerelease'] != false ||
        assets is! List) {
      throw const UpdateException(UpdateProblem.invalidResponse);
    }
    final result = <ReleaseAsset>[];
    for (final item in assets) {
      if (item is! Map<String, dynamic>) {
        throw const UpdateException(UpdateProblem.invalidResponse);
      }
      final name = item['name'],
          url = item['browser_download_url'],
          size = item['size'];
      if (name is! String || url is! String || size is! int || size < 0) {
        throw const UpdateException(UpdateProblem.invalidResponse);
      }
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !isReleaseAssetUrl(uri) ||
          uri.pathSegments[uri.pathSegments.length - 2] != 'v$version' ||
          uri.pathSegments.last != name) {
        throw const UpdateException(UpdateProblem.invalidResponse);
      }
      result.add(ReleaseAsset(name, uri, size));
    }
    return AppRelease(
      version.toString(),
      data['body'] is String ? data['body'] as String : '',
      result,
    );
  }

  Future<VerifiedPackage> verifiedPackage(
    AppRelease release,
    UpdateTarget target,
  ) async {
    final asset = release.packageFor(target);
    if (asset == null) {
      throw UpdateException(
        target.suffix == null
            ? UpdateProblem.unsupportedPlatform
            : UpdateProblem.missingAsset,
      );
    }
    final manifest = release.asset('${asset.name}.json');
    if (manifest == null) {
      throw const UpdateException(UpdateProblem.missingAsset);
    }
    final data = await _json(manifest.url);
    final hash = data['sha256'];
    if (data['schema_version'] != 1 ||
        data['repository'] != releaseRepository ||
        data['release_tag'] != 'v${release.version}' ||
        data['version'] != release.version ||
        data['platform'] != target.platform ||
        data['file'] != asset.name ||
        data['build_number'] is! int ||
        (data['build_number'] as int) < 1 ||
        data['flutter_sha'] is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(data['flutter_sha'] as String) ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const UpdateException(UpdateProblem.verification);
    }
    final base = data['build_number'] as int;
    final offset = target.os == 'android'
        ? (target.arch == 'arm64-v8a' ? 2000 : 4000)
        : 0;
    final code = data['android_version_code'] ?? base + offset;
    if (code is! int || code != base + offset) {
      throw const UpdateException(UpdateProblem.verification);
    }
    return VerifiedPackage(asset, hash, code);
  }
}
