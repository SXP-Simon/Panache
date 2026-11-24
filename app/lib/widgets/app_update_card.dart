import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/updates/update_controller.dart';
import '../services/updates/update_model.dart';
import '../services/updates/update_notes.dart';
import 'workbench_card.dart';

class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({
    super.key,
    required this.controller,
    required this.onReload,
    this.compact = false,
    this.onRestart,
  });
  final UpdateController controller;
  final Future<void> Function() onReload;
  final bool compact;
  final Future<void> Function()? onRestart;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context)!;
      final c = controller;
      final changes = summarizeReleaseNotes(c.release?.notes ?? '');
      return WorkbenchCard(
        key: const ValueKey('app-updates'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.system_update_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.appUpdates,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ..._status(context, l),
              const SizedBox(height: 16),
              _actions(context, l),
              if (!compact)
                SwitchListTile.adaptive(
                  key: const ValueKey('auto-check-updates'),
                  contentPadding: EdgeInsets.zero,
                  value: c.autoCheck,
                  onChanged: c.setAutoCheck,
                  title: Text(l.updateAutoCheck),
                  subtitle: Text(l.updateAutoCheckHelp),
                ),
              if (!compact && c.preferenceFailed)
                Text(l.updatePreferenceFailed),
              if (!c.web && c.installed?.target.os != 'ios')
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(l.updateInstructions),
                  children: [
                    Text(
                      c.installed?.target.os == 'android'
                          ? l.updateAndroidHelp
                          : l.updateDesktopHelp,
                    ),
                  ],
                ),
              if (!compact && changes.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(l.updateNotes),
                  children: [
                    for (final change in changes)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check, size: 18),
                        title: Text(change),
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
    },
  );

  List<Widget> _status(BuildContext context, AppLocalizations l) {
    final c = controller;
    final problem = _problemLabel(c.problem, l);
    return [
      Text(
        '${l.updateInstalled}: ${c.installed?.version.isNotEmpty == true ? c.installed!.version : l.updateVersionUnknown}',
      ),
      if (c.release != null || c.deployed != null)
        Text(
          '${l.updateLatest}: ${c.web ? c.deployed!.version : c.release!.version}',
        ),
      const SizedBox(height: 12),
      Text(
        _phaseLabel(c.phase, l),
        key: const ValueKey('update-status'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (problem != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(problem, key: const ValueKey('update-problem')),
        ),
      const SizedBox(height: 8),
      Text(_platformHelp(c, l)),
      if ({
        UpdatePhase.preparing,
        UpdatePhase.restarting,
      }.contains(c.phase)) ...[
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
      ],
      if (c.phase == UpdatePhase.downloading) ...[
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: c.total == 0 ? null : c.received / c.total,
        ),
        const SizedBox(height: 8),
        Text(
          '${(c.received / 1048576).toStringAsFixed(1)} / ${(c.total / 1048576).toStringAsFixed(1)} MB',
        ),
      ],
      if (c.downloadedPath != null) ...[
        const SizedBox(height: 12),
        SelectableText(c.release?.packageFor(c.installed!.target)?.name ?? ''),
        if (c.installed?.target.os != 'android')
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(l.updateSavedLocation),
            children: [SelectableText(c.downloadedPath!)],
          ),
      ],
    ];
  }

  Widget _actions(BuildContext context, AppLocalizations l) {
    final c = controller;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (!compact)
          OutlinedButton.icon(
            key: const ValueKey('check-updates'),
            onPressed: c.busy || c.opening ? null : c.check,
            icon: const Icon(Icons.refresh),
            label: Text(l.checkUpdates),
          ),
        ..._packageActions(l),
        if (c.web)
          FilledButton.icon(
            onPressed: c.busy ? null : onReload,
            icon: const Icon(Icons.refresh),
            label: Text(l.updateReload),
          ),
        OutlinedButton.icon(
          onPressed: () async {
            if (!await launchUrl(
                  c.release?.page ?? releasesPage,
                  mode: LaunchMode.externalApplication,
                ) &&
                context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(l.updateOpenFailed)));
            }
          },
          icon: const Icon(Icons.open_in_new),
          label: Text(l.updateReleasePage),
        ),
      ],
    );
  }

  List<Widget> _packageActions(AppLocalizations l) {
    final c = controller;
    final restart = c.desktopAutomatic ? onRestart : null;
    switch (c.phase) {
      case UpdatePhase.downloading:
      case UpdatePhase.preparing:
      case UpdatePhase.restarting:
        return [
          TextButton.icon(
            onPressed: c.cancel,
            icon: const Icon(Icons.close),
            label: Text(l.cancel),
          ),
        ];
      case UpdatePhase.available:
      case UpdatePhase.failed:
        if (c.web || c.release == null || !c.canDownload) return const [];
        return [
          FilledButton.icon(
            key: const ValueKey('download-update'),
            onPressed: restart ?? c.download,
            icon: const Icon(Icons.download_outlined),
            label: Text(restart == null ? l.updateDownload : l.updateRestart),
          ),
        ];
      case UpdatePhase.ready:
        return _readyActions(l, restart);
      case UpdatePhase.idle:
      case UpdatePhase.checking:
      case UpdatePhase.current:
        return const [];
    }
  }

  List<Widget> _readyActions(
    AppLocalizations l,
    Future<void> Function()? restart,
  ) {
    final c = controller;
    final restartReady = c.problem == UpdateProblem.desktopUnavailable
        ? null
        : restart;
    final desktopLabel = restartReady == null
        ? l.updateOpenArchive
        : l.updateRestart;
    return [
      FilledButton.icon(
        key: const ValueKey('open-update'),
        onPressed: c.opening ? null : restartReady ?? c.open,
        icon: const Icon(Icons.open_in_new),
        label: Text(
          c.installed?.target.os == 'android' ? l.updateInstall : desktopLabel,
        ),
      ),
      if (c.problem == UpdateProblem.anotherInstance)
        OutlinedButton.icon(
          key: const ValueKey('manual-update'),
          onPressed: c.opening ? null : c.open,
          icon: const Icon(Icons.folder_open),
          label: Text(l.updateOpenArchive),
        ),
    ];
  }
}

String _phaseLabel(UpdatePhase phase, AppLocalizations l) => switch (phase) {
  UpdatePhase.idle => l.updateIdle,
  UpdatePhase.checking => l.updateChecking,
  UpdatePhase.current => l.updateCurrent,
  UpdatePhase.available => l.updateAvailable,
  UpdatePhase.downloading => l.updateDownloading,
  UpdatePhase.ready => l.updateReady,
  UpdatePhase.preparing => l.updatePreparing,
  UpdatePhase.restarting => l.updateRestarting,
  UpdatePhase.failed => l.updateFailed,
};

String? _problemLabel(UpdateProblem? problem, AppLocalizations l) =>
    switch (problem) {
      null => null,
      UpdateProblem.network => l.updateNetwork,
      UpdateProblem.rateLimited => l.updateRateLimited,
      UpdateProblem.invalidResponse => l.updateInvalidResponse,
      UpdateProblem.unknownVersion => l.updateUnknownVersion,
      UpdateProblem.unsupportedPlatform => l.updateUnsupported,
      UpdateProblem.missingAsset => l.updateMissingAsset,
      UpdateProblem.verification => l.updateVerification,
      UpdateProblem.cancelled => l.updateCancelled,
      UpdateProblem.storage => l.updateStorage,
      UpdateProblem.openFailed => l.updateOpenFailed,
      UpdateProblem.desktopUnavailable => l.updateDesktopUnavailable,
      UpdateProblem.saveFailed => l.updateSaveFailed,
      UpdateProblem.restartDeferred => l.updateRestartDeferred,
      UpdateProblem.restartCancelled => l.updateRestartCancelled,
      UpdateProblem.anotherInstance => l.updateAnotherInstance,
    };

String _platformHelp(UpdateController c, AppLocalizations l) {
  if (c.web) return l.updateWebHelp;
  return switch (c.installed?.target.os) {
    'android' => l.updateAndroidSummary,
    'ios' => l.updateIosHelp,
    _ =>
      c.desktopAutomatic ? l.updateDesktopSummary : l.updateDesktopUnavailable,
  };
}
