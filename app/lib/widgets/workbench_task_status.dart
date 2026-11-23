import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'workbench_motion.dart';

List<Widget> workbenchTaskStatus(
  BuildContext context, {
  required String error,
  required int? queueWaitSeconds,
  required bool generating,
  required String phase,
  required String stage,
  required int pagesCompleted,
  required VoidCallback? onCancel,
  required VoidCallback onDismissError,
}) {
  final l = AppLocalizations.of(context)!;
  final taskStatus = generating
      ? Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              if (onCancel != null)
                TextButton.icon(
                  key: const ValueKey('cancel-generation'),
                  onPressed: onCancel,
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(l.stopGeneration),
                ),
              Text(switch (phase) {
                'pending' => l.pending,
                'completed' => l.completed,
                'cancelling' => l.stoppingTask,
                _ => stage == 'exporting' ? l.exportingTask : l.processing,
              }),
              if (pagesCompleted > 0) Text(l.generatedPages(pagesCompleted)),
            ],
          ),
        )
      : const SizedBox(width: double.infinity);
  return [
    if (error.isNotEmpty)
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Material(
          animationDuration: Duration.zero,
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text(
              error == 'validation'
                  ? l.validation
                  : queueWaitSeconds != null
                  ? '${l.queueFull} ${queueWaitSeconds}s'
                  : error,
            ),
            trailing: TextButton.icon(
              label: Text(l.close),
              onPressed: onDismissError,
              icon: const Icon(Icons.close),
            ),
          ),
        ),
      ),
    MediaQuery.disableAnimationsOf(context)
        ? taskStatus
        : AnimatedSize(
            duration: WorkbenchMotion.pane,
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: taskStatus,
          ),
  ];
}
