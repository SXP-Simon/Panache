import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/engine_failure.dart';
import 'dialogs/connection_dialog.dart';
import 'dialogs/illustration_dialog.dart';
import 'dialogs/pdf_import_dialog.dart';
import 'pdf_workbench.dart';
import '../services/pdf_pages.dart';
import 'dialogs/local_font_dialog.dart';
import '../services/local_fonts.dart';
import 'dialogs/paper_area_dialog.dart';
import '../utils/image_data.dart';
import '../utils/image_markers.dart';
import 'dialogs/text_tools_dialogs.dart';
import 'dialogs/text_preview_dialog.dart';
import '../services/api.dart';
import '../services/illustration_import.dart';
import '../services/workspace.dart';
import '../models/fine_edit.dart';
import '../services/desktop_exit.dart';
import '../services/workspace_documents.dart';
import '../utils/text_tools.dart';
import 'editor_preparation.dart';
import '../widgets/workbench_controls.dart';
import '../widgets/fine_preview.dart';
import '../widgets/workbench_editor.dart';
import '../widgets/workbench_preview.dart';
import '../widgets/workbench_layout.dart';
import '../widgets/ink_parameter_controls.dart';
import '../widgets/workbench_information.dart';
import '../widgets/workbench_guide.dart';
import '../widgets/workbench_settings.dart';
import '../widgets/workbench_shell.dart';
import '../theme/handwriting_theme.dart';
import '../services/updates/update_controller.dart';
import '../services/updates/update_prompt_coordinator.dart';
import 'dialogs/app_update_dialog.dart';

class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    this.workspace,
    this.updates,
    this.themeColor = defaultThemeColor,
    this.secondaryThemeColor = defaultSecondaryThemeColor,
    this.onPaletteChanged,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
    this.reduceMotion = false,
    this.onReduceMotionChanged,
    this.initialDestination = 0,
    this.guideUnread = false,
    this.onGuideOpened,
    required this.toggleLocale,
    required this.toggleTheme,
  });
  final Workspace? workspace;
  final UpdateController? updates;
  final Color themeColor, secondaryThemeColor;
  final ThemeMode themeMode;
  final Future<bool> Function(ThemeMode)? onThemeModeChanged;
  final bool reduceMotion;
  final Future<bool> Function(bool)? onReduceMotionChanged;
  final Future<bool> Function(Color, Color)? onPaletteChanged;
  final int initialDestination;
  final bool guideUnread;
  final VoidCallback? onGuideOpened;
  final VoidCallback toggleLocale, toggleTheme;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> with WidgetsBindingObserver {
  late final Workspace w;
  final editor = TextEditingController();
  TextEditingValue? lastEditorSelection;
  final editorFocus = FocusNode();
  final editorPane = GlobalKey();
  final previewPane = GlobalKey();
  final form = GlobalKey<FormState>();
  final undo = UndoHistoryController();
  int destination = 0, mobileTab = 0;
  SettingsSection settingsSection = SettingsSection.layout;
  Timer? liveTimer;
  int? liveSubmitted;
  bool livePreview = false;
  bool fineFullscreen = false;
  bool composing = false;
  int navigationRevision = 0;
  bool operation = false;
  int settingsRevision = 0;
  bool restored = false;
  bool firstFrameReady = false;
  bool recoveryShown = false;
  UpdatePromptCoordinator? updatePrompts;
  late final EditorPreparation preparation;
  WorkspaceDocuments get documents => WorkspaceDocuments(w);
  AppLocalizations get l => AppLocalizations.of(context)!;
  bool get english => Localizations.localeOf(context).languageCode == 'en';
  bool get locked => w.busy || editingLocked;
  bool get editingLocked =>
      operation ||
      preparation.running ||
      {
        UpdatePhase.preparing,
        UpdatePhase.restarting,
      }.contains(widget.updates?.phase);
  // This context is above Scaffold, before it consumes body keyboard insets.
  bool get keyboardVisible => MediaQuery.viewInsetsOf(context).bottom > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    destination = widget.initialDestination;
    w = widget.workspace ?? Workspace();
    preparation = EditorPreparation(
      readText: () => editor.text,
      applyText: (text) => replace(text, keepPreparation: true),
      onFailure: () => notify(l.prepareTextFailed),
    )..addListener(refreshPreparation);
    editor.text = w.text;
    editor.addListener(rememberEditorSelection);
    w.addListener(refresh);
    widget.updates?.addListener(refreshUpdates);
    if (widget.updates case final updates?) {
      updatePrompts = UpdatePromptCoordinator(
        controller: updates,
        ready: () {
          final state = WidgetsBinding.instance.lifecycleState;
          return mounted &&
              firstFrameReady &&
              (state == null || state == AppLifecycleState.resumed) &&
              ModalRoute.of(context)?.isCurrent == true &&
              !locked &&
              !updates.busy &&
              !updates.opening;
        },
        present: (_) async {
          final accepted = await showAppUpdateDialog(context, updates);
          if (!mounted || accepted != true) return;
          if (updates.web) {
            await reloadUpdatedWeb();
          } else {
            await showAppUpdateProgress(
              context,
              updates,
              onReload: reloadUpdatedWeb,
              onRestart: updateDesktop,
            );
          }
        },
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      firstFrameReady = true;
      if (mounted && destination == 1) widget.onGuideOpened?.call();
      updatePrompts?.evaluate();
    });
    if (widget.workspace == null) unawaited(w.initialize());
  }

  void refreshPreparation() => setState(() {});

  void refreshUpdates() {
    if (mounted &&
        !recoveryShown &&
        widget.updates?.installed?.recovered == true) {
      recoveryShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notify(l.updateRolledBack);
      });
    }
    if (mounted) setState(() {});
  }

  void refresh() {
    if (!mounted) return;
    if (w.initialized && !restored) {
      restored = true;
      settingsRevision++;
    }
    if (editor.text != w.text) {
      if (preparation.running) unawaited(preparation.stop());
      preparation.forgetFormatting();
      editor.value = TextEditingValue(
        text: w.text,
        selection: TextSelection.collapsed(offset: w.text.length),
      );
    }
    if (livePreview && editor.text.trim().isEmpty && w.pages.isNotEmpty) {
      w.pages = [];
      w.page = 0;
    }
    setState(() {});
    scheduleLivePreview();
    updatePrompts?.evaluate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(w.persist());
    updatePrompts?.evaluate();
  }

  @override
  void dispose() {
    liveTimer?.cancel();
    preparation.dispose();
    WidgetsBinding.instance.removeObserver(this);
    w.removeListener(refresh);
    widget.updates?.removeListener(refreshUpdates);
    updatePrompts?.dispose();
    if (widget.workspace == null) w.dispose();
    editor.dispose();
    fineSource.dispose();
    fineInspector.dispose();
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
      if (mounted) {
        setState(() => operation = false);
        scheduleLivePreview();
      }
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

  void rememberEditorSelection() {
    final value = editor.value;
    final selection = value.selection;
    fineSource.value = selection.isValid && !selection.isCollapsed
        ? (start: selection.start, end: selection.end)
        : null;
    final composingNow =
        value.composing.isValid && !value.composing.isCollapsed;
    if (composing != composingNow) {
      composing = composingNow;
      scheduleLivePreview();
    }
    if (value.selection.isValid && value.selection.end <= value.text.length) {
      lastEditorSelection = value;
    } else if (lastEditorSelection?.text != value.text) {
      lastEditorSelection = null;
    }
  }

  final fineSource = ValueNotifier<FineRange?>(null);
  final fineInspector = FineInspectorSlot();

  Future<bool> enterFineEdit() async {
    w.text = editor.text;
    final result = await w.enterFineEdit();
    if (mounted && result) liveSubmitted = w.editRevision;
    return result;
  }

  void insert(String value, {TextSelection? at}) {
    final selection = at ?? editor.selection;
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

  void replace(String value, {bool keepPreparation = false}) {
    if (!keepPreparation) preparation.forgetFormatting();
    editor.text = value;
    w.text = value;
    w.edit();
  }

  Future<void> importText() => action(() async {
    final file = await pick(['txt', 'docx', 'pdf', 'rtf']);
    if (file == null || !mounted) return;
    if (file.name.toLowerCase().endsWith('.pdf')) {
      final api = w.api;
      final mode = await choosePdfImport(context, api.base);
      if (!mounted || mode == null) return;
      if (mode != PdfImportMode.text) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => PdfWorkbench(
              file: file,
              mode: mode,
              ink: Color(w.settings.inkLook.color),
              fetch: (index) async => PdfSourcePage.fromJson(
                await api.pdfPage(file, index, mode.name),
                index,
              ),
              loadFont: () =>
                  loadPdfHandwritingFont(w.fontFile, w.settings.font),
              save: (bytes) => saveBytes(
                bytes,
                'pdf',
                name: '${file.name.substring(0, file.name.length - 4)}-Panache',
              ),
            ),
          ),
        );
        return;
      }
    }
    await documents.importText(file);
  });
  Future<void> insertImage() => action(() async {
    // Capture before the native picker/dialog changes focus. No text edit is
    // committed until decoding and confirmation both succeed.
    final originalText = editor.text;
    final previous = lastEditorSelection;
    final selection = previous != null && previous.text == originalText
        ? previous.selection
        : TextSelection.collapsed(offset: originalText.length);
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
    final before = originalText.substring(0, selection.start);
    final after = originalText.substring(selection.end);
    final leading = before.isEmpty || before.endsWith('\n') ? '' : '\n';
    final trailing = after.startsWith('\n') ? '' : '\n';
    insert('$leading![插图 $id|$value%]$trailing', at: selection);
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

  void scheduleLivePreview() {
    liveTimer?.cancel();
    if (!livePreview ||
        destination != 0 ||
        locked ||
        !w.generation.available ||
        editor.text.trim().isEmpty ||
        w.generation.previewRevision == w.editRevision ||
        liveSubmitted == w.editRevision ||
        composing) {
      return;
    }
    liveTimer = Timer(
      Duration(milliseconds: w.settings.fullPreview ? 750 : 350),
      () {
        if (!mounted || locked || destination != 0 || !livePreview) return;
        if (composing) return;
        liveSubmitted = w.editRevision;
        unawaited(w.generate(live: true));
      },
    );
  }

  void setLivePreview(bool enabled) {
    setState(() {
      livePreview = enabled;
      liveSubmitted = null;
    });
    scheduleLivePreview();
  }

  Future<void> generate({bool preview = true, bool pdf = false}) async {
    if (!(form.currentState?.validate() ?? w.settings.valid)) {
      notify(l.validation);
      return;
    }
    w.text = editor.text;
    if (!preview && w.finePreviewNeedsRefresh) {
      liveSubmitted = w.editRevision;
      final refreshed = await w.generate();
      if (!mounted || !refreshed || w.previewStale) return;
    }
    if (preview) liveSubmitted = w.editRevision;
    final navigation = navigationRevision;
    final succeeded = await w.generate(preview: preview, pdf: pdf);
    if (!mounted || !succeeded) return;
    if (!preview && w.exportBytes != null) {
      await action(() => saveBytes(w.exportBytes!, w.exportExtension));
      return;
    }
    if (preview && w.pages.isNotEmpty) {
      if (MediaQuery.sizeOf(context).width >= 900) return;
      if (navigation == navigationRevision &&
          destination == 0 &&
          !w.previewStale) {
        selectPane(2);
      }
    }
  }

  void setFineFullscreen(bool value) {
    if (fineFullscreen == value) return;
    if (value) FocusScope.of(context).unfocus();
    setState(() => fineFullscreen = value);
  }

  void selectPane(int index) {
    FocusScope.of(context).unfocus();
    setState(() {
      mobileTab = index;
      navigationRevision++;
    });
  }

  void selectDestination(int index) {
    FocusScope.of(context).unfocus();
    setState(() {
      destination = index;
      navigationRevision++;
    });
    if (index == 1) widget.onGuideOpened?.call();
    scheduleLivePreview();
  }

  void openGuideTarget(GuideTarget target) {
    if (target != GuideTarget.preview) fineInspector.value?.close();
    setState(() {
      destination = 0;
      mobileTab = switch (target) {
        GuideTarget.editor => 0,
        GuideTarget.layout => 1,
        GuideTarget.preview => 2,
      };
      if (target == GuideTarget.layout) {
        settingsSection = SettingsSection.layout;
      }
      navigationRevision++;
    });
    scheduleLivePreview();
  }

  void selectSettingsSection(SettingsSection section) {
    FocusScope.of(context).unfocus();
    setState(() {
      settingsSection = section;
      mobileTab = 1;
      navigationRevision++;
    });
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
            if (!locked && !fineFullscreen) unawaited(generate());
            return null;
          },
        ),
      },
      child: PopScope(
        canPop:
            !fineFullscreen &&
            destination == 0 &&
            (MediaQuery.sizeOf(context).width >= 900 || mobileTab == 0),
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (fineFullscreen) {
            setFineFullscreen(false);
          } else if (destination != 0) {
            selectDestination(0);
          } else {
            selectPane(0);
          }
        },
        child: WorkbenchShell(
          fineFullscreen: fineFullscreen,
          guideUnread: widget.guideUnread,
          updateAvailable: widget.updates?.phase == UpdatePhase.available,
          version: w.version,
          destination: destination,
          onDestinationSelected: selectDestination,
          connected: w.connected,
          managedBackend: w.managedBackend,
          locked: locked,
          onConnection: connectionDialog,
          onToggleLocale: widget.toggleLocale,
          onToggleTheme: widget.toggleTheme,
          themeColor: widget.themeColor,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
          secondaryThemeColor: widget.secondaryThemeColor,
          onPaletteChanged: widget.onPaletteChanged,
          reduceMotion: widget.reduceMotion,
          onReduceMotionChanged: widget.onReduceMotionChanged,
          workspaceBuilder: workspace,
          informationBuilder: information,
        ),
      ),
    ),
  );

  Widget workspace(bool wide, double width) => WorkbenchLayout(
    wide: wide,
    fineFullscreen: fineFullscreen,
    keyboardVisible: keyboardVisible,
    width: width,
    error: w.error,
    queueWaitSeconds: w.generation.queueWaitSeconds,
    busy: locked,
    generating: w.busy,
    progress: w.progress,
    phase: w.phase,
    stage: w.generation.stage,
    pagesCompleted: w.generation.pagesCompleted,
    mobileTab: mobileTab,
    settingsSection: settingsSection,
    onSectionSelected: selectSettingsSection,
    livePreview: livePreview,
    onLivePreview: setLivePreview,
    fullPreview: w.settings.fullPreview,
    onFullPreview: (value) {
      w.settings.fullPreview = value;
      w.edit();
    },
    pageCount: w.pages.length,
    formKey: form,
    editorView: editorPanel(),
    settingsView: settingsPanel(wide),
    buildPreview: (toolbar) => previewPanel(toolbar, wide: wide),
    fineInspector: fineInspector,
    onDismissError: () {
      w.error = '';
      w.emit();
    },
    onTabChanged: selectPane,
    onPreview: generate,
    onPdf: () => generate(preview: false, pdf: true),
    onZip: () => generate(preview: false),
    onCancel: w.busy && !w.stopping && w.api.supportsCancel
        ? () => action(w.cancel, allowBusy: true)
        : null,
  );

  Widget editorPanel() => WorkbenchEditor(
    key: editorPane,
    controller: editor,
    focusNode: editorFocus,
    undo: undo,
    locked: editingLocked,
    images: w.images,
    onEditImage: editImage,
    onOpenGuide: () => selectDestination(1),
    guideUnread: widget.guideUnread,
    onUndo: () {
      final text = preparation.undoText(editor.text);
      if (text != null) {
        replace(text, keepPreparation: true);
      } else {
        undo.undo();
      }
    },
    onRedo: () {
      final text = preparation.redoText(editor.text);
      if (text != null) {
        replace(text, keepPreparation: true);
      } else {
        undo.redo();
      }
    },
    onChanged: (value) {
      preparation.forgetFormatting();
      w.text = collapseImages(value, w.images);
      w.edit();
    },
    preparing: preparation.running,
    preparationStopping: preparation.stopping,
    onStopPreparation: preparation.stop,
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
          identifier: 'insert-image',
          description: l.insertImageHelp,
        ),
        EditorAction(
          l.pageBreak,
          Icons.insert_page_break_outlined,
          locked ? null : () => insert('\n---\n'),
          description: l.pageBreakHelp,
        ),
        EditorAction(
          l.prepareText,
          Icons.format_clear,
          locked ? null : prepareTextDialog,
          identifier: 'prepare-text',
          description: l.prepareTextHelp,
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

  Future<void> adjustPaperArea() async {
    final paper = w.background;
    if (paper == null || locked) return;
    late final Size size;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(paper.bytes);
      try {
        final image = await ui.ImageDescriptor.encoded(buffer);
        try {
          size = Size(image.width.toDouble(), image.height.toDouble());
        } finally {
          image.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      if (mounted) notify(l.paperAreaLoadFailed);
      return;
    }
    if (!mounted || locked || !identical(w.background, paper)) return;
    if (size.shortestSide < 16) {
      notify(l.paperAreaLoadFailed);
      return;
    }
    final layout = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => PaperAreaDialog(
        bytes: paper.bytes,
        size: size,
        values: Map.of(w.settings.values),
      ),
    );
    if (!mounted ||
        locked ||
        layout == null ||
        !identical(w.background, paper)) {
      return;
    }
    settingsRevision++;
    if (documents.applyPaperArea(paper, layout)) notify(l.paperAreaApplied);
  }

  Future<void> detectPaper() async {
    try {
      if (await documents.detectBackground() && mounted) {
        setState(() => settingsRevision++);
        notify(l.paperIdentificationDone);
      }
    } on EngineFailure catch (error) {
      if (mounted) {
        notify(switch (error.code) {
          'image_limit' || 'upload_limit' => l.paperImageTooLarge,
          _ => l.paperIdentificationFailed,
        });
      }
    } catch (_) {
      if (mounted) notify(l.paperIdentificationFailed);
    }
  }

  Widget settingsPanel(bool wide) => WorkbenchSettings(
    settings: w.settings,
    fonts: w.fonts,
    fontFile: w.fontFile,
    background: w.background,
    settingsRevision: settingsRevision,
    locked: editingLocked,
    activeSection: settingsSection,
    onSectionChanged: wide ? null : selectSettingsSection,
    inkControls: InkParameterControls(
      look: w.settings.inkLook,
      onChanged: editingLocked ? null : w.editInk,
      colorKey: const ValueKey('settings-ink-color'),
    ),
    onEdited: w.edit,
    onSelectFont: (value) {
      w.settings.font = value;
      w.fontFile = null;
      w.edit();
    },
    onColorSelected: (value) {
      final ink = w.settings.inkLook;
      w.editInk((
        opacity: ink.opacity,
        thickness: ink.thickness,
        softness: ink.softness,
        color: value.toARGB32(),
      ));
    },
    onBrowseLocalFonts: w.managedBackend && w.api.supportsLocalFonts
        ? () => action(() async {
            final font = await showDialog<LocalFont>(
              context: context,
              builder: (_) => LocalFontDialog(api: w.api),
            );
            if (font == null || !mounted) return;
            final file = await w.api.readLocalFont(font);
            if (!mounted) return;
            w.fontFile = file;
            w.edit();
          })
        : null,
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
      if (file == null) return;
      try {
        if (!await documents.setPaperBackground(file) || !mounted) return;
      } on EngineFailure catch (error) {
        if (error.code != 'image_limit') rethrow;
        if (mounted) notify(l.paperImageTooLarge);
        return;
      }
      await detectPaper();
    }),
    onDetectBackground: () => action(detectPaper),
    onAdjustBackground: adjustPaperArea,
    onRemoveBackground: () {
      w.background = null;
      w.pages = [];
      w.page = 0;
      w.edit();
    },
  );

  Widget previewPanel(Widget? toolbar, {required bool wide}) =>
      WorkbenchPreview(
        key: previewPane,
        toolbar: toolbar,
        pages: w.pages,
        inkPages: w.inkPages,
        inkLook: w.settings.inkLook,
        onFineEdit: w.api.supportsFineEdit && editor.text.trim().isNotEmpty
            ? enterFineEdit
            : null,
        fineAdjustments: w.fineAdjustments,
        onFineChanged: w.applyFineEdits,
        onFineHistory: (redo) => w.stepFineHistory(redo: redo),
        canFineUndo: w.canFineUndo,
        canFineRedo: w.canFineRedo,
        fineSource: fineSource,
        fineInspector: wide ? fineInspector : null,
        onFineCanvasSelect: () => fineSource.value = null,
        fineFullscreen: fineFullscreen,
        onFineFullscreen: wide ? null : setFineFullscreen,
        stale: w.previewStale,
        page: w.page,
        version: '',
        locked: locked,
        backgroundBytes: w.background?.bytes,
        onAdjustBackground: w.background == null ? null : adjustPaperArea,
        onPageChanged: (page) {
          w.page = page;
          w.emit();
        },
        onSaveImage: () => action(
          () async => saveBytes(
            await w.currentPreviewImage(),
            'png',
            name: 'Panache-${w.page + 1}',
          ),
        ),
        onSaveExport: w.exportBytes == null
            ? null
            : () => action(() => saveBytes(w.exportBytes!, w.exportExtension)),
      );

  Future<void> connectionDialog() async {
    final base = await showConnectionDialog(context, initialBase: w.api.base);
    if (mounted && base != null) await action(() => w.setBase(base));
  }

  Future<void> prepareTextDialog() async {
    if (locked) return;
    final mode = await showPrepareTextDialog(
      context,
      initialMode: preparation.tableMode,
    );
    if (!mounted || mode == null || locked) return;
    await preparation.run(mode, english: english);
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

  Future<void> reloadUpdatedWeb() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.updateReload),
        content: Text(l.updateReloadConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.updateReload),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (!await w.persistDraft()) {
        if (mounted) notify(l.updateSaveFailed);
        return;
      }
    } catch (_) {
      if (mounted) notify(l.updateSaveFailed);
      return;
    }
    widget.updates?.host.reload();
  }

  Future<void> updateDesktop() async {
    final updates = widget.updates;
    if (updates == null) return;
    await updates.updateAndRestart(
      persist: () async {
        w.text = editor.text;
        return w.persistDraft();
      },
      canRestart: () => mounted && !w.busy && !operation,
      requestExit: requestDesktopUpdateExit,
    );
  }

  Widget information() => destination == 1
      ? WorkbenchGuide(onOpen: openGuideTarget)
      : WorkbenchInformation(
          updates: widget.updates,
          onReload: reloadUpdatedWeb,
          onRestart: updateDesktop,
        );
}

class _PreviewIntent extends Intent {
  const _PreviewIntent();
}
