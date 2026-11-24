part of '../process_identity.dart';

class _Mac {
  static final _library = DynamicLibrary.open('/usr/lib/libproc.dylib');
  static final _info = _library
      .lookupFunction<
        Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32),
        int Function(int, int, int, Pointer<Void>, int)
      >('proc_pidinfo');
  static final _path = _library
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('proc_pidpath');
  static final _errno = DynamicLibrary.process()
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );

  static List<int> pids() {
    final list = _library
        .lookupFunction<
          Int32 Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)
        >('proc_listallpids');
    for (var count = 1024; count <= 262144; count *= 2) {
      final buffer = calloc<Int32>(count);
      try {
        final length = list(buffer.cast(), count * 4);
        if (length < 0) reject('process_identity_denied');
        if (length < count) return buffer.asTypedList(length).toList();
      } finally {
        calloc.free(buffer);
      }
    }
    reject('process_identity_denied');
  }

  static String? _start(int pid, Pointer<Uint8> buffer) {
    final result = _info(pid, 3, 0, buffer.cast(), 136);
    if (result != 136) {
      if ({2, 3}.contains(_errno().value)) return null;
      reject('process_identity_denied');
    }
    // Public XNU proc_bsdinfo: 12 uint32s, 48 chars, six uint32s,
    // followed by the two uint64 creation-time values (offsets 120/128).
    final data = ByteData.sublistView(buffer.asTypedList(136));
    if (data.getUint32(12, Endian.host) != pid) {
      reject('process_identity_changed');
    }
    if (data.getUint32(4, Endian.host) == 5) return null;
    return 'macos:${data.getUint64(120, Endian.host)}:${data.getUint64(128, Endian.host)}';
  }

  static ProcessIdentity? capture(int pid) {
    final buffer = calloc<Uint8>(136), path = calloc<Uint8>(4096);
    try {
      final started = _start(pid, buffer);
      if (started == null) return null;
      if (_path(pid, path.cast(), 4096) < 1) {
        if (_start(pid, buffer) == null) return null;
        reject('process_identity_denied');
      }
      final executable = path.cast<Utf8>().toDartString();
      final after = _start(pid, buffer);
      if (after == null) return null;
      if (after != started) reject('process_identity_changed');
      return ProcessIdentity(pid, executable, started);
    } finally {
      calloc.free(buffer);
      calloc.free(path);
    }
  }
}
