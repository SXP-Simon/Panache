import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import 'dialogs/connection_dialog.dart';
import 'dialogs/illustration_dialog.dart';
import '../utils/image_data.dart';
import '../utils/image_markers.dart';
import 'dialogs/text_tools_dialogs.dart';
import 'dialogs/text_preview_dialog.dart';
import '../services/api.dart';
import '../services/illustration_import.dart';
import '../services/workspace.dart';
import '../services/workspace_documents.dart';
import '../utils/text_tools.dart';
import '../utils/latex.dart';
import '../widgets/workbench_controls.dart';
import '../widgets/workbench_editor.dart';
import '../widgets/workbench_preview.dart';
import '../widgets/workbench_layout.dart';
import '../widgets/workbench_information.dart';
import '../widgets/workbench_settings.dart';
import '../widgets/workbench_shell.dart';
import '../theme/handwriting_theme.dart';

class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    this.workspace,
    this.themeColor = defaultThemeColor,
    this.onThemeColorChanged,
    this.initialDestination = 0,
    required this.toggleLocale,
    required this.toggleTheme,
  });
  final Workspace? workspace;
  final Color themeColor;
  final Future<bool> Function(Color)? onThemeColorChanged;
  final int initialDestination;
  final VoidCallback toggleLocale, toggleTheme;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> with WidgetsBindingObserver {
  late final Workspace w;
  final editor = TextEditingController();
  final editorFocus = FocusNode();
  final form = GlobalKey<FormState>();
  final undo = UndoHistoryController();
  int destination = 0, mobileTab = 0;
  bool operation = false;
  int settingsRevision = 0;
  bool restored = false;
  String tableMode = 'latex';
  WorkspaceDocuments get documents => WorkspaceDocuments(w);
  AppLocalizations get l => AppLocalizations.of(context)!;
  bool get english => Localizations.localeOf(context).languageCode == 'en';
  bool get locked => w.busy || operation;
  // This context is above Scaffold, before it consumes body keyboard insets.
  bool get keyboardVisible => MediaQuery.viewInsetsOf(context).bottom > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(w.persist());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  Future<void> action(
    Future<void> Function() work, {
    bool allowBusy = false,
  }) async {
    if (operation || (!allowBusy && w.busy)) return;
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
    String name = 'Panache',
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
    await documents.importText(file);
  });
  Future<void> insertImage() => action(() async {
    // Capture before the native picker/dialog changes focus. No text edit is
    // committed until decoding and confirmation both succeed.
    final selection = editor.selection;
    final originalText = editor.text;
    String source;
    try {
      final file = await pickIllustration();
      if (file == null || !mounted) return;
      source = await prepareIllustration(file.bytes);
    } catch (_) {
      if (mounted) notify(l.invalidIllustration);
      return;
    }
    if (!mounted) return;
    final value = await showIllustrationDialog(context, source: source);
    if (value == null || !mounted) return;
    if (editor.text != originalText) return;
    final existing = w.images.entries
        .where((entry) => entry.value == source)
        .firstOrNull;
    final id = existing?.key ?? nextIllustrationId(w.images, editor.text);
    w.images[id] = source;
    editor.selection = selection;
    insert('\n![插图 $id|$value%]\n');
  });

  Future<void> editImage(IllustrationMarker marker) => action(() async {
    final before = editor.text;
    final value = await showIllustrationDialog(
      context,
      source: w.images[marker.id],
      initialScale: marker.scale,
      removable: true,
    );
    if (value == null || !mounted || editor.text != before) return;
    editor.value = TextEditingValue(
      text: before.replaceRange(
        marker.start,
        marker.end,
        value == 0 ? '' : marker.resized(value),
      ),
      selection: TextSelection.collapsed(offset: marker.start),
    );
    w.text = editor.text;
    // Keep detached bytes for undo/redo; explicit draft reset clears assets.
    w.edit();
  });

  Future<void> generate({bool preview = true, bool pdf = false}) async {
    if (!(form.currentState?.validate() ?? w.settings.valid)) {
      notify(l.validation);
      return;
    }
    w.text = editor.text;
    final succeeded = await w.generate(preview: preview, pdf: pdf);
    if (!mounted || !succeeded) return;
    if (w.exportBytes != null) {
      await action(() => saveBytes(w.exportBytes!, w.exportExtension));
    }
    if (w.pages.isNotEmpty) setState(() => mobileTab = 2);
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
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
      child: WorkbenchShell(
        destination: destination,
        onDestinationSelected: (value) => setState(() => destination = value),
        connected: w.connected,
        managedBackend: w.managedBackend,
        locked: locked,
        onConnection: connectionDialog,
        onToggleLocale: widget.toggleLocale,
        onToggleTheme: widget.toggleTheme,
        themeColor: widget.themeColor,
        onThemeColorChanged: widget.onThemeColorChanged,
        workspaceBuilder: workspace,
        informationBuilder: information,
      ),
    ),
  );

  Widget workspace(bool wide, double width) => WorkbenchLayout(
    wide: wide,
    keyboardVisible: keyboardVisible,
    width: width,
    error: w.error,
    busy: locked,
    generating: w.busy,
    progress: w.progress,
    phase: w.phase,
    mobileTab: mobileTab,
    formKey: form,
    editorView: editorPanel(),
    settingsView: settingsPanel(),
    previewView: previewPanel(),
    onDismissError: () {
      w.error = '';
      w.emit();
    },
    onTabChanged: (index) => setState(() => mobileTab = index),
    onPreview: generate,
    onPdf: () => generate(preview: false, pdf: true),
    onZip: () => generate(preview: false),
    onCancel: w.busy && w.api.supportsCancel
        ? () => action(w.cancel, allowBusy: true)
        : null,
  );

  Widget editorPanel() => WorkbenchEditor(
    controller: editor,
    focusNode: editorFocus,
    undo: undo,
    locked: locked,
    images: w.images,
    onEditImage: editImage,
    onChanged: (value) {
      w.text = collapseImages(value, w.images);
      w.edit();
    },
    toolbar: EditorToolbar(
      moreLabel: l.editingTools,
      hint: l.editingToolsHint,
      actions: [
        EditorAction(
          l.importText,
          Icons.upload_file_outlined,
          locked ? null : importText,
          identifier: 'import-text',
          description: l.importTextHelp,
        ),
        EditorAction(
          l.insertImage,
          Icons.add_photo_alternate_outlined,
          locked ? null : insertImage,
          description: l.insertImageHelp,
        ),
        EditorAction(
          l.pageBreak,
          Icons.insert_page_break_outlined,
          locked ? null : () => insert('\n---\n'),
          description: l.pageBreakHelp,
        ),
        EditorAction(
          l.markdown,
          Icons.format_clear,
          locked ? null : markdownDialog,
          description: l.markdownHelp,
        ),
        EditorAction(
          l.latex,
          Icons.functions,
          locked ? null : () => replace(convertLatex(editor.text)),
          description: l.latexHelp,
        ),
        EditorAction(
          l.letter,
          Icons.mail_outline,
          locked ? null : letterDialog,
        ),
        EditorAction(
          l.textPreview,
          Icons.preview_outlined,
          locked ? null : textPreview,
          description: l.textPreviewHelp,
        ),
      ],
    ),
  );

  Widget settingsPanel() => WorkbenchSettings(
    settings: w.settings,
    fonts: w.fonts,
    fontFile: w.fontFile,
    background: w.background,
    settingsRevision: settingsRevision,
    locked: locked,
    onEdited: w.edit,
    onSelectFont: (value) {
      w.settings.font = value;
      w.fontFile = null;
      w.edit();
    },
    onColorSelected: (value) {
      w.settings.fill = value;
      settingsRevision++;
      w.edit();
    },
    onUploadFont: () => action(() async {
      final file = await pick(['ttf', 'otf']);
      if (file != null) {
        w.fontFile = file;
        w.edit();
      }
    }),
    onRemoveFont: () {
      w.fontFile = null;
      w.edit();
    },
    onDefaultPreset: () {
      final font = w.settings.font;
      w.settings = w.createDefaultSettings()..font = font;
      settingsRevision++;
      w.edit();
    },
    onSmallPreset: () {
      w.settings.smallPreset();
      settingsRevision++;
      if (w.fonts.contains('云烟体.ttf')) w.settings.font = '云烟体.ttf';
      w.fontFile = null;
      w.edit();
    },
    onSavePreset: () => action(() async {
      if (await w.savePreset()) notify(l.saved);
    }),
    onLoadPreset: () {
      settingsRevision++;
      if (!w.loadPreset()) notify(l.emptyPreset);
    },
    onExportPreset: () => action(
      () => saveBytes(documents.exportPreset(), 'json', name: 'Panache-preset'),
    ),
    onImportPreset: () => action(() async {
      final file = await pick(['json']);
      if (file != null) {
        settingsRevision++;
        documents.importPreset(file);
      }
    }),
    onUploadBackground: () => action(() async {
      final file = await pick(['png', 'jpg', 'jpeg']);
      if (file != null) {
        w.background = file;
        w.emit();
      }
    }),
    onDetectBackground: () => action(() async {
      await documents.detectBackground();
      settingsRevision++;
    }),
    onRemoveBackground: () {
      w.background = null;
      w.emit();
    },
  );

  Widget previewPanel() => WorkbenchPreview(
    pages: w.pages,
    page: w.page,
    version: w.version,
    locked: locked,
    onPageChanged: (page) {
      w.page = page;
      w.emit();
    },
    onSaveImage: () => action(
      () => saveBytes(w.pages[w.page], 'png', name: 'Panache-${w.page + 1}'),
    ),
    onSaveExport: w.exportBytes == null
        ? null
        : () => action(() => saveBytes(w.exportBytes!, w.exportExtension)),
  );

  Future<void> connectionDialog() async {
    final base = await showConnectionDialog(context, initialBase: w.api.base);
    if (mounted && base != null) await action(() => w.setBase(base));
  }

  Future<void> markdownDialog() async {
    final mode = await showMarkdownDialog(context, initialMode: tableMode);
    if (!mounted || mode == null) return;
    tableMode = mode;
    replace(cleanMarkdown(editor.text, tableMode: mode, english: english));
  }

  Future<void> letterDialog() async {
    final input = await showLetterDialog(
      context,
      initial: extractLetterEnding(editor.text),
    );
    if (mounted && input != null) {
      replace(formatLetter(input.body, input.signature, input.date));
    }
  }

  Future<void> textPreview() => showTextPreviewDialog(
    context,
    text: editor.text,
    onOpenLink: (uri) => unawaited(launchUrl(uri)),
  );

  Widget information() => WorkbenchInformation(guide: destination == 1);
}

class _PreviewIntent extends Intent {
  const _PreviewIntent();
}
