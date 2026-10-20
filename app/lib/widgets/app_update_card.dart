import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/updates/update_controller.dart';
import '../services/updates/update_model.dart';
import '../services/updates/update_notes.dart';

class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({
    super.key,
    required this.controller,
    required this.onReload,
    this.compact = false,
  });
  final UpdateController controller;
  final Future<void> Function() onReload;
  final bool compact;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context)!;
      final c = controller;
      final changes = summarizeReleaseNotes(c.release?.notes ?? '');
      final status = switch (c.phase) {
        UpdatePhase.idle => l.updateIdle,
        UpdatePhase.checking => l.updateChecking,
        UpdatePhase.current => l.updateCurrent,
        UpdatePhase.available => l.updateAvailable,
        UpdatePhase.downloading => l.updateDownloading,
        UpdatePhase.ready => l.updateReady,
        UpdatePhase.failed => l.updateFailed,
      };
      final problem = switch (c.problem) {
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
      };
      return Card(
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
              Text(
                '${l.updateInstalled}: ${c.installed?.version.isNotEmpty == true ? c.installed!.version : l.updateVersionUnknown}',
              ),
              if (c.release != null || c.deployed != null)
                Text(
                  '${l.updateLatest}: ${c.web ? c.deployed!.version : c.release!.version}',
                ),
              const SizedBox(height: 12),
              Text(
                status,
                key: const ValueKey('update-status'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(problem, key: const ValueKey('update-problem')),
                ),
              const SizedBox(height: 8),
              Text(
                c.web
                    ? l.updateWebHelp
                    : c.installed?.target.os == 'android'
                    ? l.updateAndroidSummary
                    : c.installed?.target.os == 'ios'
                    ? l.updateIosHelp
                    : l.updateDesktopSummary,
              ),
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
                SelectableText(
                  c.release?.packageFor(c.installed!.target)?.name ?? '',
                ),
                if (c.installed?.target.os != 'android')
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(l.updateSavedLocation),
                    children: [SelectableText(c.downloadedPath!)],
                  ),
              ],
              const SizedBox(height: 16),
              Wrap(
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
                  if (c.phase == UpdatePhase.downloading)
                    TextButton.icon(
                      onPressed: c.cancel,
                      icon: const Icon(Icons.close),
                      label: Text(l.cancel),
                    ),
                  if (!c.web &&
                      c.release != null &&
                      c.canDownload &&
                      {
                        UpdatePhase.available,
                        UpdatePhase.failed,
                      }.contains(c.phase))
                    FilledButton.icon(
                      key: const ValueKey('download-update'),
                      onPressed: c.download,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(l.updateDownload),
                    ),
                  if (c.phase == UpdatePhase.ready)
                    FilledButton.icon(
                      key: const ValueKey('open-update'),
                      onPressed: c.opening ? null : c.open,
                      icon: const Icon(Icons.open_in_new),
                      label: Text(
                        c.installed?.target.os == 'android'
                            ? l.updateInstall
                            : l.updateOpenArchive,
                      ),
                    ),
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.updateOpenFailed)),
                        );
                      }
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: Text(l.updateReleasePage),
                  ),
                ],
              ),
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
}
