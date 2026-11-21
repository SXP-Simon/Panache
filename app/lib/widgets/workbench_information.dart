import 'package:flutter/material.dart';

import 'workbench_card.dart';

import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/updates/update_controller.dart';
import 'app_update_card.dart';
import 'workbench_chapter_heading.dart';

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
            WorkbenchChapterHeading(
              title: l.about,
              introduction: l.aboutText,
              emblem: Image.asset(
                'assets/branding/panache.png',
                width: 52,
                height: 52,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(height: 24),
            WorkbenchCard(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.localDataNote),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
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
                            Uri.parse(
                              'https://github.com/SXP-Simon/Panache/issues',
                            ),
                          ),
                          icon: const Icon(Icons.bug_report_outlined),
                          label: Text(l.feedback),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(l.feedbackHelp),
                  ],
                ),
              ),
            ),
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
