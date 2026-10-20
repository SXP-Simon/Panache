import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_model.dart';
import 'update_repository.dart';

enum UpdatePhase {
  idle,
  checking,
  current,
  available,
  downloading,
  ready,
  failed,
}

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.host,
    UpdateRepository? repository,
    Future<SharedPreferences> Function()? preferences,
  }) : repository = repository ?? UpdateRepository(),
       _preferences = preferences ?? SharedPreferences.getInstance;
  final UpdateHost host;
  final UpdateRepository repository;
  final Future<SharedPreferences> Function() _preferences;
  static const autoCheckKey = 'panache.updates.autoCheck';
  static const buildId = String.fromEnvironment('PANACHE_BUILD_ID');
  InstalledApp? installed;
  AppRelease? release;
  DeployedApp? deployed;
  UpdatePhase phase = UpdatePhase.idle;
  UpdateProblem? problem;
  bool autoCheck = true, preferenceFailed = false, opening = false;
  bool _disposed = false;
  int received = 0, total = 0;
  String? downloadedPath;
  VerifiedPackage? _package;
  DownloadCancellation? _cancellation;
  bool get busy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading;
  bool get web => installed?.target.web ?? kIsWeb;
  bool get canDownload =>
      installed != null && release?.packageFor(installed!.target) != null;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      autoCheck = (await _preferences()).getBool(autoCheckKey) ?? true;
    } catch (_) {
      preferenceFailed = true;
    }
    try {
      installed = await host.installed();
    } catch (_) {
      problem = UpdateProblem.unknownVersion;
    }
    if (_disposed) return;
    _emit();
    if (autoCheck) await check();
  }

  Future<void> setAutoCheck(bool value) async {
    autoCheck = value;
    preferenceFailed = false;
    _emit();
    try {
      preferenceFailed = !await (await _preferences()).setBool(
        autoCheckKey,
        value,
      );
    } catch (_) {
      preferenceFailed = true;
    }
    _emit();
  }

  Future<void> check() async {
    if (busy || opening || _disposed) return;
    phase = UpdatePhase.checking;
    problem = null;
    _emit();
    try {
      try {
        installed ??= await host.installed();
      } catch (_) {
        throw const UpdateException(UpdateProblem.unknownVersion);
      }
      final local = parseAppVersion(installed!.version);
      if (local == null) {
        throw const UpdateException(UpdateProblem.unknownVersion);
      }
      if (web) {
        deployed = await host.deployedVersion();
        if (deployed == null) {
          throw const UpdateException(UpdateProblem.unknownVersion);
        }
        phase = deployed!.differsFrom(installed!.version, buildId)
            ? UpdatePhase.available
            : UpdatePhase.current;
      } else {
        release = await repository.latest();
        if (parseAppVersion(release!.version)!.compareTo(local) <= 0) {
          phase = UpdatePhase.current;
        } else {
          phase = UpdatePhase.available;
          if (installed!.target.suffix == null) {
            problem = UpdateProblem.unsupportedPlatform;
          } else if (release!.packageFor(installed!.target) == null ||
              release!.asset(
                    '${release!.packageFor(installed!.target)!.name}.json',
                  ) ==
                  null) {
            problem = UpdateProblem.missingAsset;
          }
        }
      }
    } on UpdateException catch (error) {
      problem = error.problem;
      phase = UpdatePhase.failed;
    } catch (_) {
      problem = UpdateProblem.network;
      phase = UpdatePhase.failed;
    }
    _emit();
  }

  Future<void> download() async {
    if (busy || opening || release == null || installed == null || _disposed) {
      return;
    }
    phase = UpdatePhase.downloading;
    problem = null;
    received = total = 0;
    downloadedPath = null;
    final cancellation = DownloadCancellation();
    _cancellation = cancellation;
    _emit();
    try {
      _package = await repository.verifiedPackage(release!, installed!.target);
      cancellation.check();
      downloadedPath = await host.download(_package!, cancellation, (
        done,
        size,
      ) {
        received = done;
        total = size;
        _emit();
      });
      cancellation.check();
      phase = UpdatePhase.ready;
    } on UpdateException catch (error) {
      problem = error.problem;
      phase = error.problem == UpdateProblem.cancelled
          ? UpdatePhase.available
          : UpdatePhase.failed;
    } catch (_) {
      problem = UpdateProblem.network;
      phase = UpdatePhase.failed;
    } finally {
      _cancellation = null;
      _emit();
    }
  }

  void cancel() => _cancellation?.cancel();

  Future<void> open() async {
    if (phase != UpdatePhase.ready ||
        opening ||
        downloadedPath == null ||
        _package == null ||
        _disposed) {
      return;
    }
    opening = true;
    problem = null;
    _emit();
    try {
      await host.open(downloadedPath!, _package!.buildNumber);
    } on UpdateException catch (error) {
      problem = error.problem;
    } catch (_) {
      problem = UpdateProblem.openFailed;
    }
    opening = false;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    repository.close();
    super.dispose();
  }
}
