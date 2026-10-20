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
  preparing,
  restarting,
  failed,
}

class UpdateNotice {
  const UpdateNotice(this.sequence, this.identity, this.automatic);
  final int sequence;
  final String identity;
  final bool automatic;
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
  DesktopPreparedUpdate? _prepared;
  bool _restartIntent = false, _restartRunning = false;
  bool get desktopAutomatic => desktop && installed!.canRestartDesktop;
  bool get desktop =>
      installed != null &&
      {'windows', 'macos', 'linux'}.contains(installed!.target.os);
  UpdateNotice? notice;
  int _noticeSequence = 0, _claimedSequence = 0;
  final Set<String> _seenIdentities = {};
  bool claimNotice(UpdateNotice candidate) {
    if (phase != UpdatePhase.available ||
        notice?.sequence != candidate.sequence ||
        candidate.sequence <= _claimedSequence) {
      return false;
    }
    _claimedSequence = candidate.sequence;
    if (candidate.automatic && _seenIdentities.contains(candidate.identity)) {
      return false;
    }
    _seenIdentities.add(candidate.identity);
    return true;
  }

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.preparing ||
      phase == UpdatePhase.restarting;
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
    if (autoCheck) await check(automatic: true);
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

  Future<void> check({bool automatic = false}) async {
    if (busy || opening || _disposed) return;
    phase = UpdatePhase.checking;
    notice = null;
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
    if (_disposed) return;
    if (phase == UpdatePhase.available) {
      final identity = web
          ? 'web:${deployed!.version}:${deployed!.buildId}'
          : 'release:${release!.version}';
      notice = UpdateNotice(++_noticeSequence, identity, automatic);
    }
    _emit();
  }

  Future<void> download() async {
    if (busy || opening || release == null || installed == null || _disposed) {
      return;
    }
    phase = UpdatePhase.downloading;
    notice = null;
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

  void cancel() {
    _restartIntent = false;
    _cancellation?.cancel();
    final prepared = _prepared;
    if (prepared != null) {
      _prepared = null;
      prepared.abort().then((_) {
        if (!_disposed) {
          phase = UpdatePhase.ready;
          problem = UpdateProblem.restartCancelled;
          _emit();
        }
      });
    }
  }

  Future<void> updateAndRestart({
    required Future<bool> Function() persist,
    required bool Function() canRestart,
    required Future<bool> Function() requestExit,
  }) async {
    if (_restartRunning ||
        busy ||
        opening ||
        _disposed ||
        host is! DesktopUpdateHost ||
        !desktopAutomatic) {
      return;
    }
    _restartRunning = true;
    _restartIntent = true;
    try {
      if (phase != UpdatePhase.ready) await download();
      if (!_restartIntent ||
          _disposed ||
          phase != UpdatePhase.ready ||
          _package == null ||
          release == null) {
        return;
      }
      if (!canRestart()) {
        problem = UpdateProblem.restartDeferred;
        return;
      }
      phase = UpdatePhase.preparing;
      problem = null;
      _emit();
      final preparingCancellation = DownloadCancellation();
      _cancellation = preparingCancellation;
      final prepared = await (host as DesktopUpdateHost).prepareRestart(
        downloadedPath!,
        _package!,
        release!.version,
        cancellation: preparingCancellation,
      );
      _prepared = prepared;
      if (!_restartIntent || _disposed) {
        await prepared.abort();
        _prepared = null;
        phase = UpdatePhase.ready;
        return;
      }
      if (!await persist()) {
        throw const UpdateException(UpdateProblem.saveFailed);
      }
      if (!_restartIntent || _disposed || !canRestart()) {
        await prepared.abort();
        _prepared = null;
        phase = UpdatePhase.ready;
        problem = UpdateProblem.restartDeferred;
        return;
      }
      prepared.arm();
      phase = UpdatePhase.restarting;
      _emit();
      if (!await requestExit()) {
        await prepared.abort();
        _prepared = null;
        phase = UpdatePhase.ready;
        problem = UpdateProblem.restartCancelled;
      }
    } on UpdateException catch (error) {
      await _prepared?.abort();
      _prepared = null;
      problem = error.problem;
      phase = downloadedPath == null ? UpdatePhase.failed : UpdatePhase.ready;
    } catch (_) {
      await _prepared?.abort();
      _prepared = null;
      problem = UpdateProblem.openFailed;
      phase = downloadedPath == null ? UpdatePhase.failed : UpdatePhase.ready;
    } finally {
      _restartRunning = false;
      _cancellation = null;
      _emit();
    }
  }

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
    notice = null;
    if (phase != UpdatePhase.restarting) cancel();
    repository.close();
    super.dispose();
  }
}
