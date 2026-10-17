import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'api.dart';
import 'uploaded_font_storage.dart';

class FontStorage implements UploadedFontStorage {
  Future<web.IDBDatabase> _open() {
    final result = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open('panache-fonts', 1);
    request.onupgradeneeded = ((web.Event event) {
      (request.result as web.IDBDatabase).createObjectStore('fonts');
    }).toJS;
    request.onsuccess = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      if (result.isCompleted) {
        database.close();
      } else {
        result.complete(database);
      }
    }).toJS;
    request.onerror = ((web.Event event) {
      if (!result.isCompleted) {
        result.completeError(StateError('Unable to open font storage'));
      }
    }).toJS;
    request.onblocked = ((web.Event event) {
      if (!result.isCompleted) {
        result.completeError(StateError('Font storage is blocked'));
      }
    }).toJS;
    return result.future;
  }

  @override
  Future<Upload?> read() async {
    final database = await _open();
    try {
      final result = Completer<Upload?>();
      final transaction = database.transaction('fonts'.toJS);
      final request = transaction.objectStore('fonts').get('selected'.toJS);
      request.onsuccess = ((web.Event event) {
        try {
          final data = request.result;
          result.complete(
            data == null ? null : decodeFont((data as JSUint8Array).toDart),
          );
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      }).toJS;
      request.onerror = ((web.Event event) {
        result.completeError(StateError('Unable to read saved font'));
      }).toJS;
      return await result.future;
    } finally {
      database.close();
    }
  }

  @override
  Future<void> write(Upload? font) async {
    final database = await _open();
    try {
      final result = Completer<void>();
      final transaction = database.transaction('fonts'.toJS, 'readwrite');
      transaction.oncomplete = ((web.Event event) {
        result.complete();
      }).toJS;
      transaction.onabort = ((web.Event event) {
        result.completeError(StateError('Unable to save font'));
      }).toJS;
      final store = transaction.objectStore('fonts');
      if (font == null) {
        store.delete('selected'.toJS);
      } else {
        store.put(encodeFont(font).toJS, 'selected'.toJS);
      }
      await result.future;
    } finally {
      database.close();
    }
  }
}
