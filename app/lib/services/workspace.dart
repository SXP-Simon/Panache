import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';
import '../utils/text_tools.dart';
import 'api.dart';
import 'workspace_storage.dart';
import 'legacy_stub.dart' if (dart.library.js_interop) 'legacy_web.dart';

class Workspace extends ChangeNotifier {
  Workspace({HandwritingApi? api, this.managedBackend = false, this.storage})
    : api = api ?? HandwritingApi(defaultBase);
  final bool managedBackend;
  static String get defaultBase {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured.replaceAll(RegExp(r'/$'), '');
    return kIsWeb ? Uri.base.origin : 'http://127.0.0.1:5006';
  }

  HandwritingApi api;
  Settings settings = Settings();
  String text = '', version = '', phase = '', error = '', taskId = '';
  List<String> fonts = [];
  List<Uint8List> pages = [];
  Map<String, String> images = {};
  Upload? fontFile, background;
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
    if (saved != null && revision == _editRevision) {
      try {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        // Restore each valid field independently; one damaged field must not
        // discard the user's otherwise readable draft.
        if (data['text'] is String) text = data['text'] as String;
        if (data['settings'] is Map<String, dynamic>) {
          settings.restore(data['settings'] as Map<String, dynamic>);
        }
        if (data['images'] is Map) {
          images = {
            for (final entry in (data['images'] as Map).entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          };
        }
      } catch (_) {
        /* Leave invalid drafts untouched until the next edit. */
      }
    }
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
    saveTimer?.cancel();
    final snapshot = jsonEncode({
      'text': text,
      'settings': settings.toJson(),
      'images': images,
    });
    return _write('flutter.workspace', snapshot);
  }

  Future<void> _write(String key, String value) {
    final storage = this.storage;
    if (storage == null) return Future<void>.value();
    // Serialize snapshots so an older, slower disk write cannot win.
    _writes = _writes.then((_) => storage.write(key, value)).catchError((
      Object e,
    ) {
      error = '$e';
      emit();
    });
    return _writes;
  }

  Future<void> savePreset() async {
    await _write('flutter.preset', jsonEncode(settings.toJson()));
  }

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

  Future<void> generate({bool preview = true, bool pdf = false}) async {
    if (disposed ||
        busy ||
        (retryAt != null && DateTime.now().isBefore(retryAt!))) {
      return;
    }
    if (text.trim().isEmpty ||
        !settings.valid ||
        (fontFile == null && settings.font == null)) {
      error = 'validation';
      emit();
      return;
    }
    final generation = ++_generation;
    bool current() => !disposed && generation == _generation;
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
        return;
      }
      taskId = submittedId;
      await persist();
      if (!current()) return;
      final deadline = DateTime.now().add(const Duration(minutes: 29));
      while (current()) {
        final data = await activeApi.status(submittedId);
        if (!current()) return;
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
      if (!current()) return;
      if (preview) {
        final rendered = await activeApi.preview(submittedId);
        if (!current()) return;
        pages = rendered;
        page = 0;
      } else {
        final response = await activeApi.result(submittedId);
        if (!current()) return;
        exportBytes = response.bodyBytes;
        exportExtension = pdf ? 'pdf' : 'zip';
      }
      progress = 100;
    } on ApiException catch (e) {
      if (!current()) return;
      error = e.waitSeconds == null ? '$e' : 'queue:${e.waitSeconds}';
      if (e.waitSeconds != null) {
        retryAt = DateTime.now().add(Duration(seconds: e.waitSeconds!));
      }
    } catch (e) {
      if (!current()) return;
      error = '$e';
    } finally {
      if (current()) {
        busy = false;
        emit();
      }
    }
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
    disposed = true;
    saveTimer?.cancel();
    unawaited(persist());
    api.close();
    pages = [];
    images = {};
    fontFile = null;
    background = null;
    exportBytes = null;
    super.dispose();
  }
}
