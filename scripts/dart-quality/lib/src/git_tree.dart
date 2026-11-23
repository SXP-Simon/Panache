import 'dart:convert';
import 'dart:io';

/// A source entry at a resolved commit. Git paths are always slash-separated.
typedef SourceEntry = ({String path, String object, String mode});

class GitTree {
  final String repo;
  final String commit;
  final List<SourceEntry> sources;

  GitTree._(this.repo, this.commit, this.sources);

  factory GitTree.read(String repo, String revision) {
    final commit = _git(repo, [
      'rev-parse',
      '--verify',
      '--end-of-options',
      '$revision^{commit}',
    ]).trim();
    final entries = _git(repo, ['ls-tree', '-rz', '--full-tree', commit]);
    final sources = <SourceEntry>[];
    for (final record in entries.split('\x00')) {
      if (!record.endsWith('.dart')) continue;
      final tab = record.indexOf('\t');
      final header = record.substring(0, tab).split(' ');
      sources.add((
        path: record.substring(tab + 1),
        object: header[2],
        mode: header[0],
      ));
    }
    return GitTree._(repo, commit, sources);
  }

  String content(SourceEntry source) =>
      _git(repo, ['cat-file', 'blob', source.object]);

  static String _git(String repo, List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      repo,
      ...args,
    ], stdoutEncoding: null);
    if (result.exitCode != 0) {
      throw StateError((result.stderr as String).trim());
    }
    return utf8.decode(result.stdout as List<int>);
  }
}
