import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api.dart';
import '../../services/local_fonts.dart';

class LocalFontDialog extends StatefulWidget {
  const LocalFontDialog({super.key, required this.api});
  final HandwritingApi api;

  @override
  State<LocalFontDialog> createState() => _LocalFontDialogState();
}

class _LocalFontDialogState extends State<LocalFontDialog> {
  final search = TextEditingController();
  final scroll = ScrollController();
  LocalFontSource source = LocalFontSource.system;
  List<LocalFont> fonts = [];
  String? directory;
  int? nextOffset;
  int generation = 0;
  bool loading = true;
  Object? error;
  Timer? debounce;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  void reload({bool typing = false, bool refresh = false}) {
    debounce?.cancel();
    generation++;
    if (scroll.hasClients) scroll.jumpTo(0);
    setState(() {
      fonts = [];
      nextOffset = null;
      error = null;
      loading = true;
    });
    if (typing) {
      debounce = Timer(const Duration(milliseconds: 200), load);
    } else {
      load(refresh: refresh);
    }
  }

  Future<void> load({bool refresh = false}) async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.api.listLocalFonts(
        source: source,
        query: search.text.trim(),
        offset: nextOffset ?? 0,
        refresh: refresh,
      );
      if (!mounted || request != generation) return;
      setState(() {
        fonts = [...fonts, ...page.fonts];
        nextOffset = page.nextOffset;
        directory = page.directory;
        loading = false;
      });
    } catch (e) {
      if (!mounted || request != generation) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  Future<void> openDirectory() async {
    final path = directory;
    if (path == null) return;
    try {
      if (await launchUrl(
        Uri.directory(path),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Show the path so it can still be opened manually.
    }
    if (mounted) {
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: SelectableText(l.openFontFolderFailed(path))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final personal = source == LocalFontSource.user;
    return AlertDialog(
      title: Text(l.localFonts),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<LocalFontSource>(
              segments: [
                ButtonSegment(
                  value: LocalFontSource.system,
                  label: Text(l.systemFonts),
                ),
                ButtonSegment(
                  value: LocalFontSource.user,
                  label: Text(l.personalFonts),
                ),
              ],
              selected: {source},
              onSelectionChanged: (selection) {
                source = selection.single;
                search.clear();
                reload();
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: search,
              onChanged: (_) => reload(typing: true),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l.searchFonts,
              ),
            ),
            if (personal)
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: directory == null ? null : openDirectory,
                        icon: const Icon(Icons.folder_open_outlined),
                        label: Text(l.openFontFolder),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l.refreshFonts,
                    onPressed: loading ? null : () => reload(refresh: true),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: fonts.length + 1,
                itemBuilder: (context, index) {
                  if (index < fonts.length) {
                    final font = fonts[index];
                    return ListTile(
                      title: Text(font.name),
                      subtitle: font.filename == font.name
                          ? null
                          : Text(
                              font.filename,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: () => Navigator.pop(context, font),
                    );
                  }
                  if (loading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (error != null) {
                    return Column(
                      children: [
                        SelectableText('${l.errorTitle}: $error'),
                        TextButton(onPressed: load, child: Text(l.retry)),
                      ],
                    );
                  }
                  if (nextOffset != null) {
                    return TextButton(
                      onPressed: load,
                      child: Text(l.moreFonts),
                    );
                  }
                  if (fonts.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        personal && search.text.trim().isEmpty
                            ? l.personalFontsEmpty
                            : l.noMatchingFonts,
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
      ],
    );
  }
}
