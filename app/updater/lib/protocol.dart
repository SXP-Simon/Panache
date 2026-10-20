import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'process_identity.dart';

const protocolVersion = 1;
const product = 'Panache';
const markerName = 'panache-install.json';
const supportedPlatforms = {'windows-x64', 'macos-arm64', 'linux-x64'};

class UpdaterFailure implements Exception {
  const UpdaterFailure(this.code);
  final String code;
  @override
  String toString() => 'UpdaterFailure($code)';
}

Never reject(String code) => throw UpdaterFailure(code);

String secureToken() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool validToken(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool validVersion(String value) =>
    RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$')
        .hasMatch(value);
Future<String> hashFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Map<String, dynamic> readJson(String path, {int maxBytes = 65536}) {
  final file = File(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file ||
      file.lengthSync() > maxBytes) {
    reject('invalid_metadata');
  }
  final value = jsonDecode(file.readAsStringSync());
  if (value is! Map<String, dynamic>) reject('invalid_metadata');
  return value;
}

String requireString(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String || value.isEmpty || value.contains('\x00')) {
    reject('invalid_metadata');
  }
  return value;
}

String executableFor(String platform) => switch (platform) {
  'windows-x64' => 'handwriting_app.exe',
  'macos-arm64' => 'Contents/MacOS/Panache',
  'linux-x64' => 'handwriting_app',
  _ => reject('unsupported_platform'),
};
String markerFor(String platform) => platform.startsWith('macos')
    ? 'Contents/Resources/$markerName'
    : markerName;

class InstallInfo {
  InstallInfo(this.platform, this.version, this.build, this.layout);
  final String platform, version, layout;
  final int build;
  String get executable => executableFor(platform);
  String get runtimeId => '$version-$build';
  factory InstallInfo.read(String root, String platform) {
    final data = readJson(p.join(root, markerFor(platform)));
    final version = requireString(data, 'version');
    final build = data['build_number'];
    final layout = requireString(data, 'layout');
    if (data['schema'] != protocolVersion ||
        data['product'] != product ||
        data['platform'] != platform ||
        !supportedPlatforms.contains(platform) ||
        !validVersion(version) ||
        build is! int ||
        build < 1 ||
        data['executable'] != executableFor(platform) ||
        layout !=
            (platform == 'windows-x64' ? 'windows-versioned' : 'bundle')) {
      reject('invalid_installation');
    }
    return InstallInfo(platform, version, build, layout);
  }
  Map<String, Object> toJson() => {
    'schema': protocolVersion,
    'product': product,
    'platform': platform,
    'version': version,
    'build_number': build,
    'layout': layout,
    'executable': executable,
  };
}

class UpdatePlan {
  UpdatePlan({
    required this.token,
    required this.target,
    required this.archive,
    required this.sha256,
    required this.platform,
    required this.version,
    required this.build,
    required this.currentVersion,
    required this.currentSha256,
    this.sidecarPid,
    required this.parent,
  });
  final String token,
      target,
      archive,
      sha256,
      platform,
      version,
      currentVersion,
      currentSha256;
  final int? sidecarPid;
  final ProcessIdentity parent;
  final int build;
  Map<String, Object> toJson() => {
    'schema': protocolVersion,
    'product': product,
    'token': token,
    'target': target,
    'archive': archive,
    'sha256': sha256,
    'platform': platform,
    'version': version,
    'build_number': build,
    'current_version': currentVersion,
    'current_sha256': currentSha256,
    'parent': parent.toJson(),
    'sidecar_pid': ?sidecarPid,
  };
  factory UpdatePlan.read(String transaction, String token) {
    validateTransactionDirectory(transaction, token);
    final data = readJson(p.join(transaction, 'request.json'));
    final target = requireString(data, 'target'),
        archive = requireString(data, 'archive');
    final platform = requireString(data, 'platform'),
        version = requireString(data, 'version');
    final current = requireString(data, 'current_version');
    final hash = requireString(data, 'sha256');
    final currentHash = requireString(data, 'current_sha256');
    final sidecar = data['sidecar_pid'];
    final parent = data['parent'];
    final build = data['build_number'];
    if (data['schema'] != protocolVersion ||
        data['product'] != product ||
        data['token'] != token ||
        !supportedPlatforms.contains(platform) ||
        !validVersion(version) ||
        !validVersion(current) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(currentHash) ||
        (sidecar != null && (sidecar is! int || sidecar < 1)) ||
        parent is! Map<String, dynamic> ||
        build is! int ||
        build < 1 ||
        !p.isAbsolute(target) ||
        !p.isAbsolute(archive)) {
      reject('invalid_plan');
    }
    final updates = p.dirname(p.dirname(transaction));
    if (p.equals(updates, target) ||
        p.isWithin(updates, target) ||
        p.isWithin(target, updates) ||
        !p.isWithin(updates, archive) ||
        !p.basename(p.dirname(archive)).startsWith('download-') ||
        !p.basename(archive).startsWith('Flutter-Panache-$version-')) {
      reject('invalid_source');
    }
    return UpdatePlan(
      token: token,
      target: target,
      archive: archive,
      sha256: hash,
      platform: platform,
      version: version,
      build: build,
      currentVersion: current,
      currentSha256: currentHash,
      sidecarPid: sidecar as int?,
      parent: ProcessIdentity.fromJson(parent),
    );
  }
}

void validateTransactionDirectory(String directory, String token) {
  if (!validToken(token) ||
      p.basename(directory) != token ||
      p.basename(p.dirname(directory)) != 'transactions' ||
      p.basename(p.dirname(p.dirname(directory))) != 'updates' ||
      !p.isAbsolute(directory)) {
    reject('invalid_transaction');
  }
  final canonical = Directory(directory).resolveSymbolicLinksSync();
  if (!p.equals(canonical, p.normalize(directory))) {
    reject('invalid_transaction');
  }
  final root = readJson(
    p.join(p.dirname(p.dirname(directory)), 'updater-root.json'),
  );
  if (root['schema'] != protocolVersion || root['product'] != product) {
    reject('invalid_transaction');
  }
}
