import 'dart:convert';
import 'dart:io';

import 'package:panache_dart_quality/src/git_tree.dart';
import 'package:panache_dart_quality/src/measurement.dart';

const usage =
    'dart run bin/dart_quality.dart [--repo PATH] [--ref REVISION] [--top N] [--json]';
const groups = ['product', 'tests', 'vendor', 'tooling'];
const metrics = ['complexity', 'nesting', 'lines'];

class Options {
  String repo = '.', revision = 'HEAD';
  int top = 5;
  bool json = false;

  Options(List<String> args) {
    final values = args.iterator;
    while (values.moveNext()) {
      final name = values.current;
      if (name == '--json') {
        json = true;
        continue;
      }
      if (!const {'--repo', '--ref', '--top'}.contains(name)) {
        throw FormatException('Unknown option $name');
      }
      if (!values.moveNext()) throw FormatException('Missing value for $name');
      final value = values.current;
      switch (name) {
        case '--repo':
          repo = value;
        case '--ref':
          revision = value;
        case '--top':
          final limit = int.tryParse(value);
          if (limit == null || limit < 1)
            throw FormatException('--top requires a positive integer');
          top = limit;
      }
    }
  }
}

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(usage);
    return;
  }
  late final Options options;
  try {
    options = Options(args);
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n$usage');
    exitCode = 64;
    return;
  }
  try {
    final tree = GitTree.read(options.repo, options.revision);
    final result = Measurement();
    for (final entry in tree.sources) {
      if (entry.mode != '100644' && entry.mode != '100755') {
        result.invalid(
          entry.path,
          'Expected a regular Git blob; mode ${entry.mode}',
        );
        continue;
      }
      try {
        result.measure(entry.path, tree.content(entry));
      } on FormatException {
        result.invalid(entry.path, 'Invalid UTF-8 content');
      }
    }
    final status = tree.sources.isEmpty
        ? 'empty'
        : result.diagnostics.isEmpty
        ? 'ok'
        : 'incomplete';
    final summaries = {for (final g in groups) g: result.groupSummary(g)};
    if (options.json) {
      stdout.writeln(
        jsonEncode({
          'schemaVersion': 1,
          'status': status,
          'revision': tree.commit,
          'dartSdk': Platform.version.split(' ').first,
          'analyzer': '10.1.0',
          'trackedDart': tree.sources.length,
          'groups': summaries,
          'files': result.files,
          'functions': result.functions,
          'diagnostics': result.diagnostics,
        }),
      );
    } else {
      stdout.writeln(
        '${tree.commit}  tracked Dart files: ${tree.sources.length}  status: $status',
      );
      for (final g in groups) {
        final stats = summaries[g]!;
        stdout.writeln(
          '\n$g: ${stats["parsed"]}/${stats["tracked"]} parsed, ${stats["scopes"]} scopes',
        );
        if (stats['scopes'] == 0) continue;
        for (final metric in metrics) {
          stdout.writeln('  Highest $metric');
          for (final f in result.ranked(g, metric, options.top)) {
            stdout.writeln(
              '    ${f[metric]}  ${f["path"]}:${f["line"]}  ${f["name"]}',
            );
          }
        }
      }
      if (tree.sources.isEmpty)
        stderr.writeln(
          'The selected revision contains no tracked .dart files.',
        );
      for (final d in result.diagnostics)
        stderr.writeln('${d["path"]}:${d["line"] ?? "-"}  ${d["message"]}');
    }
    if (status != 'ok') exitCode = 1;
  } on ProcessException catch (error) {
    stderr.writeln('Cannot run Git: ${error.message}');
    exitCode = 1;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('Invalid Git output: ${error.message}');
    exitCode = 1;
  }
}
