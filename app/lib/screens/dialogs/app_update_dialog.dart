import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/updates/update_controller.dart';
import '../../services/updates/update_model.dart';
import '../../services/updates/update_notes.dart';
import '../../widgets/app_update_card.dart';

Future<bool?> showAppUpdateDialog(
  BuildContext context,
  UpdateController controller,
) => showDialog<bool>(
  context: context,
  builder: (_) => AppUpdateAvailableDialog(controller: controller),
);

class AppUpdateAvailableDialog extends StatelessWidget {
  const AppUpdateAvailableDialog({super.key, required this.controller});
  final UpdateController controller;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final web = controller.web;
    final changes = web
        ? <String>[]
        : summarizeReleaseNotes(controller.release?.notes ?? '');
    final canUpdate =
        web || (controller.canDownload && controller.problem == null);
    return AlertDialog(
      key: const ValueKey('update-available-dialog'),
      icon: const Icon(Icons.download_rounded),
      title: Text(l.updateAvailable),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Panache ${web ? controller.deployed!.version : controller.release!.version}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              if (web)
                Text(l.updateWebPrompt)
              else if (changes.isEmpty)
                Text(l.updateNoChanges)
              else
                for (final change in changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  '),
                        Expanded(child: Text(change)),
                      ],
                    ),
                  ),
              if (controller.problem == UpdateProblem.missingAsset)
                Text(l.updateMissingAsset),
              if (controller.problem == UpdateProblem.unsupportedPlatform)
                Text(l.updateUnsupported),
              if (!web)
                TextButton.icon(
                  key: const ValueKey('update-prompt-release'),
                  onPressed: () async {
                    try {
                      if (!await launchUrl(
                        controller.release?.page ?? releasesPage,
                        mode: LaunchMode.externalApplication,
                      )) {
                        throw const UpdateException(UpdateProblem.openFailed);
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.updateOpenFailed)),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(l.updateFullNotes),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('update-prompt-later'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.updateLater),
        ),
        if (canUpdate)
          FilledButton(
            key: const ValueKey('update-prompt-now'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(web ? l.updateReloadNow : l.updateNow),
          ),
      ],
    );
  }
}

Future<void> showAppUpdateProgress(
  BuildContext context,
  UpdateController controller, {
  required Future<void> Function() onReload,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      AppUpdateProgressDialog(controller: controller, onReload: onReload),
);

class AppUpdateProgressDialog extends StatefulWidget {
  const AppUpdateProgressDialog({
    super.key,
    required this.controller,
    required this.onReload,
  });
  final UpdateController controller;
  final Future<void> Function() onReload;
  @override
  State<AppUpdateProgressDialog> createState() =>
      _AppUpdateProgressDialogState();
}

class _AppUpdateProgressDialogState extends State<AppUpdateProgressDialog> {
  bool started = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => started = true);
      unawaited(widget.controller.download());
    });
  }

  @override
  void dispose() {
    if (widget.controller.phase == UpdatePhase.downloading) {
      widget.controller.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final canClose =
          started && !widget.controller.busy && !widget.controller.opening;
      return PopScope(
        canPop: canClose,
        child: Dialog(
          key: const ValueKey('update-progress-dialog'),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    child: AppUpdateCard(
                      controller: widget.controller,
                      onReload: widget.onReload,
                      compact: true,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: TextButton(
                      key: const ValueKey('close-update-progress'),
                      onPressed: canClose ? () => Navigator.pop(context) : null,
                      child: Text(AppLocalizations.of(context)!.updateClose),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
