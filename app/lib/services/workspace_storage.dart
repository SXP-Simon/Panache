import 'package:shared_preferences/shared_preferences.dart';

/// Storage adapter; workspace orchestration does not depend on plugin setup.
abstract interface class WorkspaceStorage {
  String? read(String key);
  Future<void> write(String key, String value);
}

class PreferencesWorkspaceStorage implements WorkspaceStorage {
  PreferencesWorkspaceStorage(this.preferences);
  final SharedPreferences preferences;

  @override
  String? read(String key) =>
      preferences.get(key) is String ? preferences.getString(key) : null;

  @override
  Future<void> write(String key, String value) async {
    if (!await preferences.setString(key, value)) {
      throw StateError('Unable to save workspace');
    }
  }
}
