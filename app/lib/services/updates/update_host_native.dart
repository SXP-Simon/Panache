import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_model.dart';
import 'update_download.dart';
import 'update_http_native.dart';

UpdateHost createUpdateHost() => NativeUpdateHost();

class NativeUpdateHost implements UpdateHost {
  static const channel = MethodChannel('io.github.sxpsimon.panache/updates');
  final Map<String, String> _verifiedHashes = {};
  @override
  Future<InstalledApp> installed() async {
    final info = await PackageInfo.fromPlatform();
    final os = Platform.operatingSystem;
    var arch = switch (Abi.current()) {
      Abi.windowsX64 || Abi.linuxX64 || Abi.macosX64 => 'x64',
      Abi.windowsArm64 || Abi.linuxArm64 || Abi.macosArm64 => 'arm64',
      _ => 'unknown',
    };
    if (Platform.isAndroid) {
      final abis =
          await channel.invokeListMethod<String>('supportedAbis') ?? [];
      arch = androidUpdateTarget(abis).arch;
    }
    return InstalledApp(
      info.version == '0.1.0' && info.buildNumber == '1' ? '' : info.version,
      UpdateTarget(os, arch),
    );
  }

  @override
  Future<DeployedApp?> deployedVersion() async => null;

  Future<Directory> _directory() async {
    final root = Platform.isAndroid
        ? Directory((await channel.invokeMethod<String>('cacheDirectory'))!)
        : Directory('${(await getApplicationSupportDirectory()).path}/updates');
    await root.create(recursive: true);
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory &&
          entity.parent.path == root.path &&
          entity.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last
              .startsWith('download-')) {
        try {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete(recursive: true);
          }
        } on FileSystemException {
          // Cache cleanup cannot prevent checking/downloading a new update.
        }
      }
    }
    return root;
  }

  @override
  Future<String> download(
    VerifiedPackage package,
    DownloadCancellation cancellation,
    void Function(int, int) progress,
  ) async {
    final asset = package.asset;
    if (!isReleaseAssetUrl(asset.url) ||
        !RegExp(r'^Flutter-Panache-[\w.\-]+$').hasMatch(asset.name) ||
        asset.size <= 0 ||
        asset.size > 2 * 1024 * 1024 * 1024) {
      throw const UpdateException(UpdateProblem.verification);
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    // Respect the operating system's configured proxy environment.
    client.findProxy = HttpClient.findProxyFromEnvironment;
    cancellation.abort = () => client.close(force: true);
    try {
      var uri = asset.url;
      HttpClientResponse? response;
      for (var redirects = 0; redirects <= 5; redirects++) {
        cancellation.check();
        await configureUpdateProxy(
          client,
          uri,
        ).timeout(const Duration(seconds: 20));
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 20));
        request.followRedirects = false;
        response = await request.close().timeout(const Duration(seconds: 20));
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (location == null) {
            throw const UpdateException(UpdateProblem.network);
          }
          final target = uri.resolve(location);
          if (redirects == 5 ||
              target.scheme != 'https' ||
              target.hasPort ||
              target.userInfo.isNotEmpty ||
              !{
                'github.com',
                'release-assets.githubusercontent.com',
                'objects.githubusercontent.com',
              }.contains(target.host)) {
            throw const UpdateException(UpdateProblem.verification);
          }
          await response.drain<void>().timeout(const Duration(seconds: 20));
          uri = target;
          continue;
        }
        break;
      }
      if (response == null || response.statusCode != 200) {
        throw const UpdateException(UpdateProblem.network);
      }
      final path = await saveVerifiedUpdate(
        stream: response,
        root: await _directory(),
        package: package,
        cancellation: cancellation,
        progress: progress,
      );
      _verifiedHashes[path] = package.sha256;
      return path;
    } on UpdateException {
      rethrow;
    } on FileSystemException {
      throw const UpdateException(UpdateProblem.storage);
    } catch (_) {
      cancellation.check();
      throw const UpdateException(UpdateProblem.network);
    } finally {
      client.close(force: true);
      cancellation.abort = null;
    }
  }

  @override
  Future<void> open(String path, int buildNumber) async {
    try {
      final expected = _verifiedHashes[path];
      if (expected == null ||
          (await sha256.bind(File(path).openRead()).first).toString() !=
              expected) {
        throw const UpdateException(UpdateProblem.verification);
      }
      if (Platform.isAndroid) {
        await channel.invokeMethod<void>('install', {
          'path': path,
          'buildNumber': buildNumber,
          'sha256': expected,
        });
      } else if (!await launchUrl(
        Uri.file(path),
        mode: LaunchMode.externalApplication,
      )) {
        throw const UpdateException(UpdateProblem.openFailed);
      }
    } on UpdateException {
      rethrow;
    } catch (_) {
      throw const UpdateException(UpdateProblem.openFailed);
    }
  }

  @override
  void reload() {}
}
