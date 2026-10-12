import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';
import '../utils/text_tools.dart';
import 'api.dart';
import 'legacy_stub.dart' if (dart.library.js_interop) 'legacy_web.dart';

class Workspace extends ChangeNotifier {
  Workspace({HandwritingApi? api}) : api = api ?? HandwritingApi(defaultBase);
  static String get defaultBase {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured.replaceAll(RegExp(r'/$'), '');
    return kIsWeb ? Uri.base.origin : 'http://127.0.0.1:5005';
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
  SharedPreferences? prefs;
  Timer? saveTimer;
  int? legacyFontIndex;

  Future<void> initialize() async {
    prefs = await SharedPreferences.getInstance();
    if (disposed) return;
    final saved = prefs!.getString('flutter.workspace');
    if (saved != null) {
      try {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        text = data['text'] as String? ?? '';
        settings.restore(Map<String, dynamic>.from(data['settings'] as Map));
        images = Map<String, String>.from(data['images'] as Map? ?? {});
      } catch (_) {
        /* Leave invalid drafts untouched until the next edit. */
      }
    }
    if (saved == null) {
      final legacy = readLegacyDraft();
      if (legacy.isNotEmpty) {
        settings.restore(legacy);
        text = collapseImages('${legacy['text'] ?? ''}', images);
        legacyFontIndex = int.tryParse('${legacy['selectedOption']}');
      }
    }
    final base = prefs!.getString('flutter.api');
    if (base != null && base != api.base && !kIsWeb) {
      api.close();
      api = HandwritingApi(base);
    }
    initialized = true;
    emit();
    await connect();
  }

  Future<void> connect() async {
    error = '';
    try {
      fonts = List<String>.from(await api.getJson('/api/fonts_info'));
      if (legacyFontIndex != null &&
          legacyFontIndex! > 0 &&
          legacyFontIndex! <= fonts.length) {
        settings.font = fonts[legacyFontIndex! - 1];
        legacyFontIndex = null;
      }
      if (!fonts.contains(settings.font)) settings.font = fonts.firstOrNull;
      connected = true;
      try {
        version = '${(await api.getJson('/api/version'))['version'] ?? ''}';
      } catch (_) {
        version = '';
      }
    } catch (e) {
      connected = false;
      error = '$e';
    }
    emit();
  }

  Future<void> setBase(String base) async {
    api.close();
    api = HandwritingApi(base.replaceAll(RegExp(r'/$'), ''));
    await prefs?.setString('flutter.api', api.base);
    await connect();
  }

  void edit() {
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 400), persist);
    emit();
  }

  Future<void> persist() async {
    if (prefs == null) return;
    try {
      await prefs!.setString(
        'flutter.workspace',
        jsonEncode({
          'text': text,
          'settings': settings.toJson(),
          'images': images,
        }),
      );
    } catch (e) {
      error = '$e';
      emit();
    }
  }

  Future<void> savePreset() async {
    await prefs?.setString('flutter.preset', jsonEncode(settings.toJson()));
  }

  bool loadPreset() {
    final saved = prefs?.getString('flutter.preset');
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
    if (busy || (retryAt != null && DateTime.now().isBefore(retryAt!))) return;
    if (text.trim().isEmpty ||
        !settings.valid ||
        (fontFile == null && settings.font == null)) {
      error = 'validation';
      emit();
      return;
    }
    busy = true;
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
      taskId = await activeApi.submit(fields, {
        'font_file': ?fontFile,
        'background_image': ?background,
      });
      await persist();
      final deadline = DateTime.now().add(const Duration(minutes: 29));
      while (!disposed) {
        final data = await activeApi.status(taskId);
        phase = '${data['task_status'] ?? data['status']}';
        progress = ((data['task_progress'] ?? data['progress']) as num? ?? 0)
            .toInt()
            .clamp(0, 100);
        emit();
        if (phase == 'failed' || phase == 'error') {
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
      if (disposed) return;
      final response = await activeApi.result(taskId);
      if (preview) {
        if (response.headers['content-type']?.contains('json') ?? false) {
          final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
          pages = [
            for (final image in data['images'] as List)
              base64Decode(image as String),
          ];
        } else {
          pages = [response.bodyBytes];
        }
        page = 0;
      } else {
        exportBytes = response.bodyBytes;
        exportExtension = pdf ? 'pdf' : 'zip';
      }
      progress = 100;
    } on ApiException catch (e) {
      error = e.waitSeconds == null ? '$e' : 'queue:${e.waitSeconds}';
      if (e.waitSeconds != null) {
        retryAt = DateTime.now().add(Duration(seconds: e.waitSeconds!));
      }
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      emit();
    }
  }

  void emit() {
    if (!disposed) notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    saveTimer?.cancel();
    unawaited(persist());
    api.close();
    super.dispose();
  }
}
