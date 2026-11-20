import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/updates/update_controller.dart';
import 'app_update_card.dart';

class WorkbenchInformation extends StatelessWidget {
  const WorkbenchInformation({
    super.key,
    this.updates,
    this.onReload,
    this.onRestart,
  });
  final UpdateController? updates;
  final Future<void> Function()? onReload, onRestart;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Image.asset(
              'assets/branding/panache.png',
              width: 64,
              height: 64,
              excludeFromSemantics: true,
            ),
            const SizedBox(height: 24),
            Text(l.about, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 24),
            Text(l.aboutText, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 24),
            Text(l.localDataNote),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: l.appTitle,
                  ),
                  icon: const Icon(Icons.description_outlined),
                  label: Text(l.licenses),
                ),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse('https://github.com/SXP-Simon/Panache/issues'),
                  ),
                  icon: const Icon(Icons.bug_report_outlined),
                  label: Text(l.feedback),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(l.feedbackHelp),
            if (updates != null && onReload != null) ...[
              const SizedBox(height: 24),
              AppUpdateCard(
                controller: updates!,
                onReload: onReload!,
                onRestart: onRestart,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
