import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';
import '../utils/text_tools.dart';
import '../utils/image_data.dart';
import 'api.dart';
import 'engine_gateway.dart';
import '../view_models/generation_view_model.dart';
import 'workspace_storage.dart';
import 'uploaded_font_storage.dart';
import 'legacy_stub.dart' if (dart.library.js_interop) 'legacy_web.dart';

class Workspace extends ChangeNotifier {
  Workspace({
    HandwritingApi? api,
    this.managedBackend = false,
    this.storage,
    UploadedFontStorage? fontStorage,
    Settings Function()? settingsFactory,
  }) : fontStorage = fontStorage ?? createUploadedFontStorage(),
       api = api ?? HandwritingApi(defaultBase),
       _settingsFactory = settingsFactory ?? Settings.new,
       settings = (settingsFactory ?? Settings.new)() {
    generation.addListener(emit);
  }
  final Settings Function() _settingsFactory;

  /// Platform adapters inject defaults; restored user settings take priority.
  Settings createDefaultSettings() => _settingsFactory();
  final bool managedBackend;
  static String get defaultBase {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured.replaceAll(RegExp(r'/$'), '');
    return kIsWeb ? Uri.base.origin : 'http://127.0.0.1:5006';
  }

  HandwritingApi api;
  Settings settings;
  String text = '', version = '';
  final generation = GenerationViewModel();
  List<String> fonts = [];
  Map<String, String> images = {};
  Upload? _background;
  bool backgroundRuled = false;
  Upload? get background => _background;
  set background(Upload? value) {
    if (!identical(value, _background)) backgroundRuled = false;
    _background = value;
  }

  Upload? _fontFile;
  // Draft edits must not cancel an in-flight font restore; font choices must.
  int _fontRevision = 0;
  bool _fontRestorePending = false;
  Upload? get fontFile => _fontFile;
  set fontFile(Upload? value) {
    _fontFile = value;
    ++_fontRevision;
    _fontRestorePending = false;
  }

  final UploadedFontStorage fontStorage;
  Upload? _savedFont;
  bool connected = false, disposed = false, initialized = false;
  WorkspaceStorage? storage;
  Future<void> _writes = Future<void>.value();
  int _connection = 0, _editRevision = 0;
  String? get previewTaskId => generation.previewTaskId;
  bool get previewStale =>
      pages.isNotEmpty && generation.previewRevision != _editRevision;
  bool _initializing = false;
  bool get stopping => generation.stopping;
  Timer? saveTimer;
  int? legacyFontIndex;

  String get phase => generation.phase;
  set phase(String value) => generation.phase = value;
  String get error => generation.error;
  set error(String value) {
    generation.error = value;
    generation.errorCode = null;
    generation.queueWaitSeconds = null;
  }

  String get taskId => generation.taskId;
  set taskId(String value) => generation.taskId = value;
  int get progress => generation.progress;
  set progress(int value) => generation.progress = value;
  int get page => generation.page;
  set page(int value) => generation.page = value;
  DateTime? get retryAt => generation.retryAt;
  set retryAt(DateTime? value) => generation.retryAt = value;
  bool get busy => generation.busy;
  set busy(bool value) => generation.busy = value;
  List<Uint8List> get pages => generation.pages;
  set pages(List<Uint8List> value) => generation.pages = value;
  Uint8List? get exportBytes => generation.exportBytes;
  set exportBytes(Uint8List? value) => generation.exportBytes = value;
  String get exportExtension => generation.exportExtension;
  set exportExtension(String value) => generation.exportExtension = value;

  Future<void> initialize() async {
    if (initialized || _initializing || disposed) return;
    final revision = _editRevision;
    _initializing = true;
    try {
      storage ??= PreferencesWorkspaceStorage(
        await SharedPreferences.getInstance(),
      );
    } finally {
      _initializing = false;
    }
    if (disposed) return;
    final saved = storage!.read('flutter.workspace');
    var restoreUploadedFont = false;
    if (saved != null && revision == _editRevision) {
      try {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        // Restore each valid field independently; one damaged field must not
        // discard the user's otherwise readable draft.
        if (data['text'] is String) text = data['text'] as String;
        if (data['settings'] is Map<String, dynamic>) {
          settings.restore(data['settings'] as Map<String, dynamic>);
        }
        restoreUploadedFont = data['uploadedFont'] == true;
        if (data['images'] is Map) {
          images = {
            for (final entry in (data['images'] as Map).entries)
              if (entry.key is String &&
                  int.tryParse(entry.key as String) != null &&
                  entry.value is String &&
                  decodeImageData(entry.value as String) != null)
                entry.key as String: entry.value as String,
          };
        }
      } catch (_) {
        /* Leave invalid drafts untouched until the next edit. */
      }
    }
    if (restoreUploadedFont) {
      final fontRevision = _fontRevision;
      _fontRestorePending = true;
      try {
        final restoredFont = await fontStorage.read();
        _savedFont = restoredFont;
        if (fontRevision == _fontRevision && !disposed) {
          _fontFile = restoredFont;
        }
      } catch (_) {
        // Missing or damaged uploaded fonts fall back to the selected bundled font.
      } finally {
        _fontRestorePending = false;
      }
    }
    if (disposed) return;
    if (saved == null && revision == _editRevision) {
      final legacy = readLegacyDraft();
      if (legacy.isNotEmpty) {
        settings.restore(legacy);
        text = collapseImages('${legacy['text'] ?? ''}', images);
        legacyFontIndex = int.tryParse('${legacy['selectedOption']}');
      }
    }
    final base = storage!.read('flutter.api');
    if (base != null && base != api.base && !kIsWeb && !managedBackend) {
      api.close();
      api = HandwritingApi(base);
    }
    initialized = true;
    if (revision != _editRevision) await persist();
    emit();
    await connect();
  }

  Future<void> connect() async {
    if (disposed) return;
    final connection = ++_connection;
    final engine = ApiEngineGateway(api);
    error = '';
    try {
      final loadedFonts = await engine.loadFonts();
      if (disposed || connection != _connection) return;
      fonts = loadedFonts;
      if (legacyFontIndex != null &&
          legacyFontIndex! > 0 &&
          legacyFontIndex! <= fonts.length) {
        settings.font = fonts[legacyFontIndex! - 1];
        legacyFontIndex = null;
      }
      if (!fonts.contains(settings.font)) settings.font = fonts.firstOrNull;
      connected = true;
      try {
        final info = await engine.loadInfo();
        if (disposed || connection != _connection) return;
        version = info.version;
        engine.configure(info);
      } catch (_) {
        if (disposed || connection != _connection) return;
        version = '';
      }
    } catch (e) {
      if (disposed || connection != _connection) return;
      connected = false;
      error = '$e';
    }
    emit();
  }

  Future<void> setBase(String base) async {
    if (managedBackend || disposed || busy) return;
    ++_connection;
    api.close();
    api = HandwritingApi(base.replaceAll(RegExp(r'/$'), ''));
    await _write('flutter.api', api.base);
    await connect();
  }

  void edit() {
    if (disposed) return;
    ++_editRevision;
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 400), persist);
    emit();
  }

  /// Flush immediately when the app becomes inactive or goes to background.
  Future<void> persist() => disposed ? _writes : persistDraft().then((_) {});

  /// Reports persistence success before a user-confirmed page reload.
  Future<bool> persistDraft() {
    if (disposed) return Future.value(false);
    saveTimer?.cancel();
    final font = fontFile;
    final snapshot = jsonEncode({
      'text': text,
      'settings': settings.toJson(),
      'images': images,
      'uploadedFont': font != null || _fontRestorePending,
    });
    return _write(
      'flutter.workspace',
      snapshot,
      font: font,
      saveFont: !_fontRestorePending,
    );
  }

  Future<bool> _write(
    String key,
    String value, {
    Upload? font,
    bool saveFont = false,
  }) {
    final storage = this.storage;
    if (storage == null) return Future<bool>.value(false);
    // Serialize snapshots and recover the queue after a failed write, while
    // preserving an explicit success outcome for user-initiated saves.
    final operation = _writes
        .then((_) async {
          if (saveFont && !identical(font, _savedFont)) {
            await fontStorage.write(font);
            _savedFont = font;
          }
          await storage.write(key, value);
        })
        .then(
          (_) => true,
          onError: (Object e, StackTrace stackTrace) {
            error = '$e';
            emit();
            return false;
          },
        );
    _writes = operation.then((_) {});
    return operation;
  }

  Future<bool> savePreset() =>
      _write('flutter.preset', jsonEncode(settings.toJson()));

  bool loadPreset() {
    final saved = storage?.read('flutter.preset');
    if (saved == null) return false;
    try {
      settings.restore(Map<String, dynamic>.from(jsonDecode(saved)));
      edit();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> generate({bool preview = true, bool pdf = false}) async {
    if (disposed ||
        busy ||
        (retryAt != null && DateTime.now().isBefore(retryAt!))) {
      return false;
    }
    if (text.trim().isEmpty ||
        !settings.valid ||
        (fontFile == null && settings.font == null)) {
      error = 'validation';
      emit();
      return false;
    }
    final revision = _editRevision;
    final fields = settings.form(
      expandImages(text, images),
      preview: preview,
      pdf: pdf,
    );
    if (background != null) {
      fields.remove('width');
      fields.remove('height');
      fields['background_ruled'] = '$backgroundRuled';
    }
    final request = GenerationRequest(fields, {
      'font_file': ?fontFile,
      'background_image': ?background,
    });
    return generation.generate(
      request,
      ApiEngineGateway(api),
      revision: revision,
      preview: preview,
      pdf: pdf,
      onSubmitted: persist,
    );
  }

  Future<void> cancel() => generation.cancel();

  void emit() {
    if (!disposed) notifyListeners();
  }

  @override
  void dispose() {
    ++_connection;
    saveTimer?.cancel();
    unawaited(persist());
    disposed = true;
    generation.removeListener(emit);
    generation.shutdown(api.close);
    pages = [];
    images = {};
    fontFile = null;
    background = null;
    exportBytes = null;
    super.dispose();
  }
}
