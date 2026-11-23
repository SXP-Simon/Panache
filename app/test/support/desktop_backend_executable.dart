import 'dart:io';

Future<String> prepareBackendExecutable(
  String executable,
  Directory directory,
) async {
  if (!Platform.isMacOS) return executable;

  // The bundled sidecar inherits its parent's sandbox. flutter_tester runs
  // outside the app sandbox, so sign a private copy for this test process.
  final source = File(executable).absolute;
  final binary = await source.copy('${directory.path}/handwriting-server');
  final arguments = ['--force', '--sign', '-', binary.path];
  final sign = await Process.run('codesign', arguments);
  if (sign.exitCode != 0) {
    throw ProcessException(
      'codesign',
      arguments,
      sign.stderr.toString(),
      sign.exitCode,
    );
  }
  final fonts = Link('${directory.path}/font_assets');
  await fonts.create('${source.parent.path}/font_assets');
  final version = File('${source.parent.path}/VERSION');
  if (await version.exists()) await version.copy('${directory.path}/VERSION');
  return binary.path;
}
