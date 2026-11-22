import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolve the running installation when Settings opens, including moved bundles.
String? desktopMcpConfig() {
  if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    return null;
  }
  return installedMcpConfig(
    Platform.operatingSystem,
    Platform.resolvedExecutable,
    fileExists: (path) => File(path).existsSync(),
    readMarker: (path) => File(path).readAsStringSync(),
  );
}

String? installedMcpConfig(
  String system,
  String executable, {
  required bool Function(String) fileExists,
  required String Function(String) readMarker,
}) {
  if (!const {'windows', 'macos', 'linux'}.contains(system)) return null;
  final windows = system == 'windows';
  final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  if (!paths.isAbsolute(executable)) return null;
  final directory = paths.dirname(executable);
  final backend = system == 'macos'
      ? paths.normalize(paths.join(directory, '..', 'Resources', 'backend'))
      : paths.join(directory, 'backend');
  var command = paths.join(
    backend,
    windows ? 'panache-mcp.exe' : 'panache-mcp',
  );
  if (!fileExists(command)) return null;
  final args = <String>[];
  if (windows &&
      paths.basename(paths.dirname(directory)).toLowerCase() == 'versions') {
    final root = paths.dirname(paths.dirname(directory));
    final marker = paths.join(root, 'panache-install.json');
    final launcher = paths.join(root, 'handwriting_app.exe');
    // Upgrades from older packages can retain a launcher without --mcp.
    if (fileExists(launcher) &&
        fileExists(marker) &&
        fileExists(paths.join(root, 'active.json'))) {
      try {
        final metadata = jsonDecode(readMarker(marker));
        if (metadata is Map && metadata['mcp_launcher'] == true) {
          command = launcher;
          args.add('--mcp');
        }
      } on FileSystemException {
        // The versioned MCP executable is also a valid entry point.
      } on FormatException {
        // A damaged marker must not prevent access to Settings.
      }
    }
  }
  return const JsonEncoder.withIndent('  ').convert({
    'mcpServers': {
      'panache': {'command': command, if (args.isNotEmpty) 'args': args},
    },
  });
}
