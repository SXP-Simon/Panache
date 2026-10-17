import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';
import '../utils/text_tools.dart';
import '../utils/image_data.dart';
import 'api.dart';
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
       settings = (settingsFactory ?? Settings.new)();
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
  String text = '', version = '', phase = '', error = '', taskId = '';
  List<String> fonts = [];
  List<Uint8List> pages = [];
  Map<String, String> images = {};
  Upload? fontFile, background;
  final UploadedFontStorage fontStorage;
  Upload? _savedFont;
  Uint8List? exportBytes;
  String exportExtension = '';
  int progress = 0, page = 0;
  DateTime? retryAt;
  bool busy = false, connected = false, disposed = false, initialized = false;
  WorkspaceStorage? storage;
  Future<void> _writes = Future<void>.value();
  int _generation = 0, _connection = 0, _editRevision = 0;
  bool _initializing = false;
  Timer? saveTimer;
  int? legacyFontIndex;

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
      try {
        final restoredFont = await fontStorage.read();
        _savedFont = restoredFont;
        if (revision == _editRevision && !disposed) fontFile = restoredFont;
      } catch (_) {
        // Missing or damaged uploaded fonts fall back to the selected bundled font.
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
    final activeApi = api;
    error = '';
    try {
      final loadedFonts = List<String>.from(
        await activeApi.getJson('/api/fonts_info'),
      );
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
        final info = await activeApi.getJson('/api/version');
        if (disposed || connection != _connection) return;
        version = '${info['version'] ?? ''}';
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
  Future<void> persist() {
    if (disposed) return _writes;
    saveTimer?.cancel();
    final font = fontFile;
    final snapshot = jsonEncode({
      'text': text,
      'settings': settings.toJson(),
      'images': images,
      'uploadedFont': font != null,
    });
    return _write(
      'flutter.workspace',
      snapshot,
      font: font,
      saveFont: true,
    ).then((_) {});
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
    final generation = ++_generation;
    bool current() => !disposed && generation == _generation;
    var succeeded = false;
    busy = true;
    taskId = '';
    error = '';
    progress = 0;
    phase = 'pending';
    exportBytes = null;
    emit();
    final activeApi = api;
    try {
      final fields = settings.form(
        expandImages(text, images),
        preview: preview,
        pdf: pdf,
      );
      if (background != null) {
        fields.remove('width');
        fields.remove('height');
      }
      final submittedId = await activeApi.submit(fields, {
        'font_file': ?fontFile,
        'background_image': ?background,
      });
      if (!current()) {
        if (activeApi.supportsCancel) await activeApi.cancelTask(submittedId);
        return false;
      }
      taskId = submittedId;
      await persist();
      if (!current()) return false;
      final deadline = DateTime.now().add(const Duration(minutes: 29));
      while (current()) {
        final data = await activeApi.status(submittedId);
        if (!current()) return false;
        phase = '${data['task_status'] ?? data['status']}';
        progress = ((data['task_progress'] ?? data['progress']) as num? ?? 0)
            .toInt()
            .clamp(0, 100);
        emit();
        if (phase == 'failed' || phase == 'error' || phase == 'cancelled') {
          throw ApiException(
            '${data['error_message'] ?? data['message'] ?? 'Task failed'}',
          );
        }
        if (phase == 'completed') break;
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Task timed out');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (!current()) return false;
      if (preview) {
        final rendered = await activeApi.preview(submittedId);
        if (!current()) return false;
        pages = rendered;
        page = 0;
      } else {
        final response = await activeApi.result(submittedId);
        if (!current()) return false;
        exportBytes = response.bodyBytes;
        exportExtension = pdf ? 'pdf' : 'zip';
      }
      progress = 100;
      succeeded = true;
    } on ApiException catch (e) {
      if (!current()) return false;
      error = e.waitSeconds == null ? '$e' : 'queue:${e.waitSeconds}';
      if (e.waitSeconds != null) {
        retryAt = DateTime.now().add(Duration(seconds: e.waitSeconds!));
      }
    } catch (e) {
      if (!current()) return false;
      error = '$e';
    } finally {
      if (current()) {
        busy = false;
        emit();
      }
    }
    return current() && succeeded;
  }

  Future<void> cancel() async {
    if (!busy || !api.supportsCancel || disposed) return;
    final activeApi = api;
    final activeId = taskId;
    final cancellation = ++_generation;
    busy = false;
    phase = 'cancelled';
    emit();
    if (activeId.isNotEmpty) {
      try {
        await activeApi.cancelTask(activeId);
      } catch (e) {
        if (disposed || cancellation != _generation) return;
        error = '$e';
        emit();
      }
    }
  }

  void emit() {
    if (!disposed) notifyListeners();
  }

  @override
  void dispose() {
    ++_generation;
    ++_connection;
    saveTimer?.cancel();
    unawaited(persist());
    disposed = true;
    api.close();
    pages = [];
    images = {};
    fontFile = null;
    background = null;
    exportBytes = null;
    super.dispose();
  }
}
