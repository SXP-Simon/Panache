import 'package:pub_semver/pub_semver.dart';

const releaseRepository = 'SXP-Simon/Panache';
final releasesPage = Uri.https('github.com', '/$releaseRepository/releases');

enum UpdateProblem {
  network,
  rateLimited,
  invalidResponse,
  unknownVersion,
  unsupportedPlatform,
  missingAsset,
  verification,
  cancelled,
  storage,
  openFailed,
  desktopUnavailable,
  saveFailed,
  restartDeferred,
  restartCancelled,
}

class UpdateException implements Exception {
  const UpdateException(this.problem);
  final UpdateProblem problem;
}

Version? parseAppVersion(String value) {
  try {
    return Version.parse(value.startsWith('v') ? value.substring(1) : value);
  } on FormatException {
    return null;
  }
}

class UpdateTarget {
  const UpdateTarget(this.os, this.arch);
  final String os, arch;
  String? get suffix => switch ('$os-$arch') {
    'android-arm64-v8a' => 'android-arm64-v8a.apk',
    'android-x86_64' => 'android-x86_64.apk',
    'windows-x64' => 'windows-x64.zip',
    'macos-arm64' => 'macos-arm64.zip',
    'linux-x64' => 'linux-x64.tar.gz',
    _ => null,
  };
  String get platform => '$os-$arch';
  bool get web => os == 'web';
}

class InstalledApp {
  const InstalledApp(
    this.version,
    this.target, {
    this.recovered = false,
    this.canRestartDesktop = true,
  });
  final bool recovered, canRestartDesktop;
  final String version;
  final UpdateTarget target;
}

UpdateTarget androidUpdateTarget(List<String> abis) => UpdateTarget(
  'android',
  abis.where((abi) => abi == 'arm64-v8a' || abi == 'x86_64').firstOrNull ??
      'unknown',
);

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url, this.size);
  final String name;
  final Uri url;
  final int size;
}

class AppRelease {
  const AppRelease(this.version, this.notes, this.assets);
  final String version, notes;
  final List<ReleaseAsset> assets;
  Uri get page =>
      Uri.https('github.com', '/$releaseRepository/releases/tag/v$version');
  ReleaseAsset? packageFor(UpdateTarget target) {
    final suffix = target.suffix;
    if (suffix == null) return null;
    return asset('Flutter-Panache-$version-$suffix');
  }

  ReleaseAsset? asset(String name) {
    final matches = assets.where((item) => item.name == name).toList();
    return matches.length == 1 ? matches.single : null;
  }
}

class VerifiedPackage {
  const VerifiedPackage(this.asset, this.sha256, this.buildNumber);
  final ReleaseAsset asset;
  final String sha256;
  final int buildNumber;
}

bool isReleaseAssetUrl(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'github.com' &&
    !uri.hasPort &&
    uri.userInfo.isEmpty &&
    uri.path.startsWith('/$releaseRepository/releases/download/');

class DownloadCancellation {
  bool cancelled = false;
  void Function()? abort;
  void cancel() {
    cancelled = true;
    abort?.call();
  }

  void check() {
    if (cancelled) throw const UpdateException(UpdateProblem.cancelled);
  }
}

abstract interface class UpdateHost {
  Future<InstalledApp> installed();
  Future<DeployedApp?> deployedVersion();
  Future<String> download(
    VerifiedPackage package,
    DownloadCancellation cancellation,
    void Function(int, int) progress,
  );
  Future<void> open(String path, int buildNumber);
  void reload();
}

class DeployedApp {
  const DeployedApp(this.version, this.buildId);
  final String version, buildId;
  bool differsFrom(String version, String buildId) =>
      (this.buildId.isNotEmpty &&
          buildId.isNotEmpty &&
          this.buildId != buildId) ||
      (parseAppVersion(this.version) != null &&
          parseAppVersion(version) != null &&
          parseAppVersion(this.version) != parseAppVersion(version));
}

abstract interface class DesktopPreparedUpdate {
  void arm();
  Future<void> abort();
}

abstract interface class DesktopUpdateHost {
  Future<DesktopPreparedUpdate> prepareRestart(
    String path,
    VerifiedPackage package,
    String version, {
    DownloadCancellation? cancellation,
  });
}
