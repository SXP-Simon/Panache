import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/settings.dart';
import '../services/api.dart';
import '../services/workspace.dart';
import '../utils/text_tools.dart';
import '../utils/latex.dart';

class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    this.workspace,
    this.initialDestination = 0,
    required this.toggleLocale,
    required this.toggleTheme,
  });
  final Workspace? workspace;
  final int initialDestination;
  final VoidCallback toggleLocale, toggleTheme;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  late final Workspace w;
  final editor = TextEditingController();
  final editorFocus = FocusNode();
  final form = GlobalKey<FormState>();
  final undo = UndoHistoryController();
  int destination = 0, mobileTab = 0;
  bool operation = false;
  int settingsRevision = 0;
  bool restored = false;
  String tableMode = 'list';
  AppLocalizations get l => AppLocalizations.of(context)!;
  bool get english => Localizations.localeOf(context).languageCode == 'en';
  bool get locked => w.busy || operation;

  @override
  void initState() {
    super.initState();
    destination = widget.initialDestination;
    w = widget.workspace ?? Workspace();
    editor.text = w.text;
    w.addListener(refresh);
    if (widget.workspace == null) unawaited(w.initialize());
  }

  void refresh() {
    if (!mounted) return;
    if (w.initialized && !restored) {
      restored = true;
      settingsRevision++;
    }
    if (editor.text != w.text) {
      editor.value = TextEditingValue(
        text: w.text,
        selection: TextSelection.collapsed(offset: w.text.length),
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    w.removeListener(refresh);
    if (widget.workspace == null) w.dispose();
    editor.dispose();
    editorFocus.dispose();
    undo.dispose();
    super.dispose();
  }

  void notify(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> action(Future<void> Function() work) async {
    if (locked) return;
    setState(() => operation = true);
    try {
      await work();
    } catch (e) {
      notify('${l.errorTitle}: $e');
    } finally {
      if (mounted) setState(() => operation = false);
    }
  }

  Future<Upload?> pick(List<String> extensions) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    if (file.bytes == null) throw StateError('Unable to read file');
    return Upload(file.name, file.bytes!);
  }

  Future<void> saveBytes(
    Uint8List bytes,
    String extension, {
    String name = 'handwriting',
  }) async {
    await FileSaver.instance.saveAs(
      name: name,
      bytes: bytes,
      fileExtension: extension,
      mimeType: switch (extension) {
        'pdf' => MimeType.pdf,
        'png' => MimeType.png,
        'json' => MimeType.json,
        _ => MimeType.zip,
      },
    );
  }

  void insert(String value) {
    final selection = editor.selection;
    final start = selection.isValid ? selection.start : editor.text.length;
    final end = selection.isValid ? selection.end : start;
    editor.value = TextEditingValue(
      text: editor.text.replaceRange(start, end, value),
      selection: TextSelection.collapsed(offset: start + value.length),
    );
    w.text = editor.text;
    w.edit();
    editorFocus.requestFocus();
  }

  void replace(String value) {
    editor.text = value;
    w.text = value;
    w.edit();
  }

  Future<void> importText() => action(() async {
    final file = await pick(['txt', 'docx', 'pdf', 'rtf']);
    if (file == null) return;
    final response = await w.api.importFile('/api/textfileprocess', file);
    replace(collapseImages(response['text'] as String, w.images));
  });
  Future<void> insertImage() => action(() async {
    final file = await pick(['png', 'jpg', 'jpeg', 'webp']);
    if (file == null || !mounted) return;
    final scale = TextEditingController(text: '50');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.insertImage),
        content: TextField(
          controller: scale,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: l.imageScale),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(scale.text);
              if (n != null && n >= 1 && n <= 100) Navigator.pop(context, n);
            },
            child: Text(l.apply),
          ),
        ],
      ),
    );
    scale.dispose();
    if (value == null) return;
    final id =
        '${w.images.keys.map(int.parse).fold(0, (a, b) => a > b ? a : b) + 1}';
    final ext = file.name.split('.').last.toLowerCase();
    w.images[id] =
        'data:image/${ext == 'jpg' ? 'jpeg' : ext};base64,${base64Encode(file.bytes)}';
    insert('\n![插图 $id|$value%]\n');
  });

  Future<void> generate({bool preview = true, bool pdf = false}) async {
    if (!(form.currentState?.validate() ?? w.settings.valid)) {
      notify(l.validation);
      return;
    }
    w.text = editor.text;
    await w.generate(preview: preview, pdf: pdf);
    if (!mounted) return;
    if (w.exportBytes != null) {
      await action(() => saveBytes(w.exportBytes!, w.exportExtension));
    }
    if (w.pages.isNotEmpty) setState(() => mobileTab = 2);
  }

  @override
  Widget build(BuildContext context) {
    final labels = [l.workspace, l.guide, l.about];
    const icons = [
      Icons.edit_note_rounded,
      Icons.menu_book_outlined,
      Icons.info_outline_rounded,
    ];
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            _PreviewIntent(),
        SingleActivator(LogicalKeyboardKey.enter, meta: true): _PreviewIntent(),
      },
      child: Actions(
        actions: {
          _PreviewIntent: CallbackAction<_PreviewIntent>(
            onInvoke: (_) {
              if (!locked) unawaited(generate());
              return null;
            },
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(l.appTitle),
            actions: [
              IconButton(
                tooltip: l.connection,
                onPressed: locked || w.managedBackend ? null : connectionDialog,
                icon: Icon(
                  w.connected
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                ),
              ),
              IconButton(
                tooltip: l.language,
                onPressed: widget.toggleLocale,
                icon: const Icon(Icons.translate),
              ),
              IconButton(
                tooltip: l.theme,
                onPressed: widget.toggleTheme,
                icon: const Icon(Icons.contrast),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final content = destination == 0
                  ? workspace(wide, constraints.maxWidth)
                  : information();
              return Row(
                children: [
                  if (wide)
                    NavigationRail(
                      selectedIndex: destination,
                      onDestinationSelected: (i) =>
                          setState(() => destination = i),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (var i = 0; i < labels.length; i++)
                          NavigationRailDestination(
                            icon: Icon(icons[i]),
                            label: Text(labels[i]),
                          ),
                      ],
                    ),
                  Expanded(child: content),
                ],
              );
            },
          ),
          bottomNavigationBar: MediaQuery.sizeOf(context).width < 900
              ? NavigationBar(
                  selectedIndex: destination,
                  onDestinationSelected: (i) => setState(() => destination = i),
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationDestination(
                        icon: Icon(icons[i]),
                        label: labels[i],
                      ),
                  ],
                )
              : null,
        ),
      ),
    );
  }

  Widget workspace(bool wide, double width) => Column(
    children: [
      if (w.error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Material(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(16),
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(
                w.error == 'validation'
                    ? l.validation
                    : w.error.startsWith('queue:')
                    ? '${l.queueFull} ${w.error.split(':').last}s'
                    : w.error,
              ),
              trailing: IconButton(
                tooltip: l.close,
                onPressed: () {
                  w.error = '';
                  w.emit();
                },
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        ),
      if (locked)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              LinearProgressIndicator(
                value: w.busy && w.progress > 0 ? w.progress / 100 : null,
              ),
              const SizedBox(height: 8),
              Text(
                w.busy
                    ? '${switch (w.phase) {
                        'pending' => l.pending,
                        'completed' => l.completed,
                        _ => l.processing,
                      }} · ${w.progress}%'
                    : l.processing,
              ),
            ],
          ),
        ),
      if (!wide)
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(
                  value: 0,
                  label: Text(l.editor),
                  icon: const Icon(Icons.edit_outlined),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text(l.parameters),
                  icon: const Icon(Icons.tune),
                ),
                ButtonSegment(
                  value: 2,
                  label: Text(l.preview),
                  icon: const Icon(Icons.visibility_outlined),
                ),
              ],
              selected: {mobileTab},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => mobileTab = s.first),
            ),
          ),
        ),
      Expanded(
        child: Form(
          key: form,
          child: Padding(
            padding: EdgeInsets.all(wide ? 20 : 8),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: width >= 1300 ? 320 : 260,
                        child: settingsPanel(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: editorPanel()),
                      const SizedBox(width: 12),
                      Expanded(child: previewPanel()),
                    ],
                  )
                : IndexedStack(
                    index: mobileTab,
                    children: [editorPanel(), settingsPanel(), previewPanel()],
                  ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            Semantics(
              identifier: 'preview-btn',
              child: FilledButton.icon(
                key: const ValueKey('generate-preview'),
                onPressed: locked ? null : () => generate(),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(l.preview),
              ),
            ),
            Semantics(
              identifier: 'generate-pdf-btn',
              child: FilledButton.tonalIcon(
                key: const ValueKey('export-pdf'),
                onPressed: locked
                    ? null
                    : () => generate(preview: false, pdf: true),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(l.exportPdf),
              ),
            ),
            Semantics(
              identifier: 'generate-image-btn',
              child: OutlinedButton.icon(
                key: const ValueKey('export-zip'),
                onPressed: locked ? null : () => generate(preview: false),
                icon: const Icon(Icons.folder_zip_outlined),
                label: Text(l.exportZip),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget panel(
    String title,
    IconData icon,
    Widget child, {
    List<Widget> actions = const [],
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: child),
        ],
      ),
    ),
  );

  Widget editorPanel() => panel(
    l.editor,
    Icons.edit_outlined,
    Column(
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            tool(l.importText, Icons.upload_file_outlined, importText),
            tool(
              l.insertImage,
              Icons.add_photo_alternate_outlined,
              insertImage,
            ),
            tool(
              l.pageBreak,
              Icons.insert_page_break_outlined,
              () => insert('\n---\n'),
            ),
            tool(l.markdown, Icons.format_clear, markdownDialog),
            tool(
              l.latex,
              Icons.functions,
              () => replace(convertLatex(editor.text)),
            ),
            tool(l.letter, Icons.mail_outline, letterDialog),
            tool(l.textPreview, Icons.preview_outlined, textPreview),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Semantics(
            identifier: 'text-input',
            child: TextField(
              key: const ValueKey('text-editor'),
              controller: editor,
              focusNode: editorFocus,
              undoController: undo,
              enabled: !locked,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: l.editorHint,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
              ),
              onChanged: (value) {
                w.text = collapseImages(value, w.images);
                w.edit();
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text('${editor.text.runes.length} ${l.characters}'),
            ),
            IconButton(
              tooltip: l.undo,
              onPressed: locked ? null : undo.undo,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: l.redo,
              onPressed: locked ? null : undo.redo,
              icon: const Icon(Icons.redo),
            ),
          ],
        ),
        Text(l.editorNote, style: Theme.of(context).textTheme.bodySmall),
        if (w.images.isNotEmpty)
          SizedBox(
            height: 72,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final image in w.images.entries)
                  if (editor.text.contains('插图 ${image.key}'))
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Tooltip(
                        message: '![插图 ${image.key}]',
                        child: Image.memory(
                          base64Decode(image.value.split(',').last),
                          width: 64,
                          height: 64,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
              ],
            ),
          ),
      ],
    ),
  );
  Widget tool(String label, IconData icon, VoidCallback callback) => Semantics(
    identifier: label == l.importText ? 'import-text' : null,
    child: IconButton(
      tooltip: label,
      onPressed: locked ? null : callback,
      icon: Icon(icon),
    ),
  );

  Widget settingsPanel() => panel(
    l.parameters,
    Icons.tune,
    ListView(
      children: [
        Semantics(
          identifier: 'font-select',
          child: DropdownButtonFormField<String>(
            key: ValueKey('font-${w.settings.font}-${w.fontFile?.name}'),
            initialValue: w.fonts.contains(w.settings.font)
                ? w.settings.font
                : null,
            isExpanded: true,
            decoration: InputDecoration(labelText: l.font),
            items: w.fonts
                .map(
                  (f) => DropdownMenuItem(
                    value: f,
                    child: Text(f, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: locked
                ? null
                : (value) {
                    w.settings.font = value;
                    w.fontFile = null;
                    w.edit();
                  },
          ),
        ),
        TextButton.icon(
          onPressed: locked
              ? null
              : () => action(() async {
                  final file = await pick(['ttf', 'otf']);
                  if (file != null) {
                    w.fontFile = file;
                    w.emit();
                  }
                }),
          icon: const Icon(Icons.upload),
          label: Text(w.fontFile?.name ?? l.uploadFont),
        ),
        if (w.fontFile != null)
          TextButton(
            onPressed: locked
                ? null
                : () {
                    w.fontFile = null;
                    w.emit();
                  },
            child: Text(l.remove),
          ),
        const Divider(),
        Text(l.presets, style: Theme.of(context).textTheme.titleSmall),
        Wrap(
          spacing: 4,
          children: [
            ActionChip(
              label: Text(l.defaultPreset),
              onPressed: locked
                  ? null
                  : () {
                      final font = w.settings.font;
                      w.settings = Settings()..font = font;
                      settingsRevision++;
                      w.edit();
                    },
            ),
            ActionChip(
              label: Text(l.smallPreset),
              onPressed: locked
                  ? null
                  : () {
                      w.settings.smallPreset();
                      settingsRevision++;
                      if (w.fonts.contains('云烟体.ttf')) {
                        w.settings.font = '云烟体.ttf';
                      }
                      w.fontFile = null;
                      w.edit();
                    },
            ),
            ActionChip(
              label: Text(l.savePreset),
              onPressed: locked
                  ? null
                  : () => action(() async {
                      await w.savePreset();
                      notify(l.saved);
                    }),
            ),
            ActionChip(
              label: Text(l.loadPreset),
              onPressed: locked
                  ? null
                  : () {
                      settingsRevision++;
                      if (!w.loadPreset()) notify(l.emptyPreset);
                    },
            ),
            ActionChip(
              label: Text(l.exportPreset),
              onPressed: locked
                  ? null
                  : () => action(
                      () => saveBytes(
                        Uint8List.fromList(
                          utf8.encode(jsonEncode(w.settings.toJson())),
                        ),
                        'json',
                        name: 'handwriting-preset',
                      ),
                    ),
            ),
            ActionChip(
              label: Text(l.importPreset),
              onPressed: locked
                  ? null
                  : () => action(() async {
                      final file = await pick(['json']);
                      if (file != null) {
                        w.settings.restore(
                          Map<String, dynamic>.from(
                            jsonDecode(utf8.decode(file.bytes)),
                          ),
                        );
                        settingsRevision++;
                        w.edit();
                      }
                    }),
            ),
          ],
        ),
        const Divider(),
        Text(l.background, style: Theme.of(context).textTheme.titleSmall),
        if (w.background != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              w.background!.bytes,
              height: 120,
              fit: BoxFit.contain,
            ),
          ),
        TextButton.icon(
          onPressed: locked
              ? null
              : () => action(() async {
                  final file = await pick(['png', 'jpg', 'jpeg']);
                  if (file != null) {
                    w.background = file;
                    w.emit();
                  }
                }),
          icon: const Icon(Icons.image_outlined),
          label: Text(w.background?.name ?? l.uploadBackground),
        ),
        if (w.background != null)
          Wrap(
            children: [
              TextButton(
                onPressed: locked
                    ? null
                    : () => action(() async {
                        final data = await w.api.importFile(
                          '/api/imagefileprocess',
                          w.background!,
                        );
                        const map = {
                          'marginLeft': 'left_margin',
                          'marginRight': 'right_margin',
                          'marginTop': 'top_margin',
                          'marginBottom': 'bottom_margin',
                          'lineSpacing': 'line_spacing',
                        };
                        for (final entry in map.entries) {
                          if (data[entry.key] is num) {
                            w.settings.values[entry.value] =
                                '${(data[entry.key] as num).round()}';
                          }
                        }
                        settingsRevision++;
                        w.edit();
                      }),
                child: Text(l.detectBackground),
              ),
              TextButton(
                onPressed: locked
                    ? null
                    : () {
                        w.background = null;
                        w.emit();
                      },
                child: Text(l.remove),
              ),
            ],
          ),
        const Divider(),
        ExpansionTile(
          title: Text(l.layout),
          initiallyExpanded: true,
          tilePadding: EdgeInsets.zero,
          children: [parameterGrid(parameters.take(9).toList())],
        ),
        ExpansionTile(
          title: Text(l.variation),
          tilePadding: EdgeInsets.zero,
          children: [parameterGrid(parameters.sublist(9, 15))],
        ),
        ExpansionTile(
          title: Text(l.strike),
          tilePadding: EdgeInsets.zero,
          children: [parameterGrid(parameters.sublist(15))],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.underlined),
          value: w.settings.underlined,
          onChanged: locked
              ? null
              : (v) {
                  w.settings.underlined = v;
                  w.edit();
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.englishSpacing),
          value: w.settings.englishSpacing,
          onChanged: locked
              ? null
              : (v) {
                  w.settings.englishSpacing = v;
                  w.edit();
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.fullPreview),
          value: w.settings.fullPreview,
          onChanged: locked
              ? null
              : (v) {
                  w.settings.fullPreview = v;
                  w.edit();
                },
        ),
        const Divider(),
        Text(l.ink),
        Wrap(
          spacing: 8,
          children: [
            for (final color in [
              (l.black, '(0, 0, 0, 255)'),
              (l.blue, '(0, 51, 153, 255)'),
              (l.red, '(180, 0, 0, 255)'),
            ])
              ChoiceChip(
                label: Text(color.$1),
                selected: w.settings.fill == color.$2,
                onSelected: locked
                    ? null
                    : (_) {
                        w.settings.fill = color.$2;
                        settingsRevision++;
                        w.edit();
                      },
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: ValueKey('fill-$settingsRevision'),
          initialValue: w.settings.fill,
          enabled: !locked,
          decoration: InputDecoration(labelText: l.customColor),
          validator: (s) =>
              RegExp(r'^\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\)$')
                      .hasMatch(s ?? '') &&
                  (s!
                      .replaceAll(RegExp(r'[()\s]'), '')
                      .split(',')
                      .every((c) => int.parse(c) <= 255))
              ? null
              : l.validation,
          onChanged: (s) {
            w.settings.fill = s;
            w.edit();
          },
        ),
      ],
    ),
  );

  Widget parameterGrid(List<Parameter> fields) => LayoutBuilder(
    builder: (context, constraints) => Wrap(
      spacing: 8,
      runSpacing: 12,
      children: [
        for (final p in fields)
          SizedBox(
            width: (constraints.maxWidth - 8) / 2,
            child: Semantics(
              identifier: p.key,
              child: TextFormField(
                key: ValueKey('${p.key}-$settingsRevision'),
                initialValue: w.settings.values[p.key],
                enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(labelText: english ? p.en : p.zh),
                validator: (s) => p.accepts(s) ? null : l.validation,
                onChanged: (s) {
                  w.settings.values[p.key] = s;
                  w.edit();
                },
              ),
            ),
          ),
      ],
    ),
  );

  Widget previewPanel() => panel(
    l.previewTitle,
    Icons.description_outlined,
    Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: w.pages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.draw_outlined,
                            size: 56,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 24),
                          Text(l.previewHint, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  )
                : InteractiveViewer(
                    minScale: .25,
                    maxScale: 5,
                    child: Center(
                      child: Semantics(
                        identifier: 'preview-image',
                        child: Image.memory(
                          w.pages[w.page],
                          key: ValueKey(
                            'page-${w.page}-${w.pages[w.page].hashCode}',
                          ),
                          fit: BoxFit.contain,
                          semanticLabel: l.preview,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        if (w.pages.isNotEmpty)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: english ? 'Previous page' : '上一页',
                onPressed: w.page > 0
                    ? () {
                        w.page--;
                        w.emit();
                      }
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${w.page + 1} / ${w.pages.length}'),
              IconButton(
                tooltip: english ? 'Next page' : '下一页',
                onPressed: w.page < w.pages.length - 1
                    ? () {
                        w.page++;
                        w.emit();
                      }
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        if (w.pages.isNotEmpty)
          TextButton.icon(
            onPressed: locked
                ? null
                : () => action(
                    () => saveBytes(
                      w.pages[w.page],
                      'png',
                      name: 'handwriting-${w.page + 1}',
                    ),
                  ),
            icon: const Icon(Icons.download),
            label: Text(l.saveImage),
          ),
        if (w.exportBytes != null)
          TextButton.icon(
            onPressed: locked
                ? null
                : () => action(
                    () => saveBytes(w.exportBytes!, w.exportExtension),
                  ),
            icon: const Icon(Icons.save_alt),
            label: Text(l.saveExport),
          ),
        if (w.version.isNotEmpty)
          Semantics(
            identifier: 'app-version',
            child: Text(
              'v${w.version}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
      ],
    ),
  );

  Future<void> connectionDialog() async {
    final controller = TextEditingController(text: w.api.base);
    final accepted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.connection),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.sameOrigin),
              const SizedBox(height: 20),
              TextField(
                controller: controller,
                decoration: InputDecoration(labelText: l.server),
                keyboardType: TextInputType.url,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              final uri = Uri.tryParse(value);
              if (uri == null ||
                  !['http', 'https'].contains(uri.scheme) ||
                  uri.host.isEmpty ||
                  uri.hasQuery ||
                  uri.hasFragment ||
                  uri.path.replaceAll('/', '').isNotEmpty) {
                notify(l.invalidServer);
                return;
              }
              Navigator.pop(context, value);
            },
            child: Text(l.connect),
          ),
        ],
      ),
    );
    controller.dispose();
    if (accepted != null) await action(() => w.setBase(accepted));
  }

  Future<void> markdownDialog() async {
    var selected = tableMode;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l.markdown),
          content: DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: InputDecoration(labelText: l.tableMode),
            items: [
              for (final option in [
                ('list', l.listMode),
                ('aligned', l.alignedMode),
                ('raw_pipe', l.pipeMode),
                ('clean', l.cleanMode),
              ])
                DropdownMenuItem(value: option.$1, child: Text(option.$2)),
            ],
            onChanged: (v) => update(() => selected = v!),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.apply),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      tableMode = selected;
      replace(
        cleanMarkdown(editor.text, tableMode: selected, english: english),
      );
    }
  }

  Future<void> letterDialog() async {
    final ending = extractLetterEnding(editor.text);
    final body = TextEditingController(text: ending.body);
    final signature = TextEditingController(text: ending.signature),
        date = TextEditingController(text: ending.date);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.letter),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: body,
                  minLines: 4,
                  maxLines: 8,
                  decoration: InputDecoration(labelText: l.body),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: signature,
                  decoration: InputDecoration(labelText: l.signature),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: date,
                  decoration: InputDecoration(labelText: l.date),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.apply),
          ),
        ],
      ),
    );
    if (accepted == true) {
      replace(formatLetter(body.text, signature.text, date.text));
    }
    body.dispose();
    signature.dispose();
    date.dispose();
  }

  Future<void> textPreview() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.textPreview),
      content: SizedBox(
        width: 640,
        height: 440,
        child: ListView(
          children: [
            MarkdownBody(
              data: editor.text,
              selectable: true,
              onTapLink: (_, href, _) {
                if (href != null &&
                    ['http', 'https'].contains(Uri.tryParse(href)?.scheme)) {
                  unawaited(launchUrl(Uri.parse(href)));
                }
              },
            ),
            const Divider(),
            for (final match in RegExp(
              r'\$\$?([^$]+)\$\$?|\\\[([\s\S]*?)\\\]|\\\((.*?)\\\)',
            ).allMatches(editor.text))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Math.tex(
                    match[1] ?? match[2] ?? match[3]!,
                    onErrorFallback: (_) => Text(match[0]!),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.close),
        ),
      ],
    ),
  );

  Widget information() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            destination == 1 ? Icons.menu_book_outlined : Icons.draw_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(
            destination == 1 ? l.guide : l.about,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 24),
          Text(
            destination == 1 ? l.guideText : l.aboutText,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (destination == 2) ...[
            const SizedBox(height: 24),
            Text(l.accountUnavailable),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse('https://github.com/14790897/handwriting-web'),
                  ),
                  icon: const Icon(Icons.code),
                  label: Text(l.project),
                ),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(
                      'https://github.com/14790897/handwriting-web/issues',
                    ),
                  ),
                  icon: const Icon(Icons.bug_report_outlined),
                  label: const Text('GitHub Issues'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const FeedbackForm(),
          ],
        ],
      ),
    ),
  );
}

class _PreviewIntent extends Intent {
  const _PreviewIntent();
}

class FeedbackForm extends StatefulWidget {
  const FeedbackForm({super.key});
  @override
  State<FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends State<FeedbackForm> {
  final email = TextEditingController(), feedback = TextEditingController();
  bool sending = false;
  @override
  void dispose() {
    email.dispose();
    feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.feedback, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            TextField(
              controller: email,
              enabled: !sending,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: l.email),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: feedback,
              enabled: !sending,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(labelText: l.feedbackHint),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: sending
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                              .hasMatch(email.text.trim()) ||
                          feedback.text.trim().isEmpty) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(l.feedbackInvalid)),
                        );
                        return;
                      }
                      setState(() => sending = true);
                      try {
                        final response = await http
                            .post(
                              Uri.parse(
                                'https://mail.14790897.xyz/api/sendEmail',
                              ),
                              headers: {'Content-Type': 'application/json'},
                              body: jsonEncode({
                                'email': email.text.trim(),
                                'feedback': feedback.text,
                              }),
                            )
                            .timeout(const Duration(seconds: 30));
                        if (response.statusCode != 200) {
                          throw ApiException('HTTP ${response.statusCode}');
                        }
                        email.clear();
                        feedback.clear();
                        messenger.showSnackBar(
                          SnackBar(content: Text(l.feedbackSent)),
                        );
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('${l.errorTitle}: $e')),
                        );
                      } finally {
                        if (mounted) setState(() => sending = false);
                      }
                    },
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(l.send),
            ),
          ],
        ),
      ),
    );
  }
}
