import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

class _Scope {
  final int lines;
  int branches = 0, nesting = 0;
  final Map<String, int> counts = {};
  _Scope(this.lines);
}

class _Scanner {
  final String path;
  final LineInfo lineInfo;
  final List<Map<String, dynamic>> rows;
  _Scanner(this.path, this.lineInfo, this.rows);
  int line(int offset) => lineInfo.getLocation(offset).lineNumber;
  void walk(AstNode node, _Scope? active, int depth, String owner) {
    if (node is ClassDeclaration) owner = node.namePart.typeName.lexeme;
    if (node is EnumDeclaration) owner = node.namePart.typeName.lexeme;
    if (node is MixinDeclaration) owner = node.name.lexeme;
    if (node is ExtensionDeclaration) {
      owner = node.name?.lexeme ?? '(extension)';
    }
    final rowName = switch (node) {
      MethodDeclaration n when n.body is! EmptyFunctionBody => n.name.lexeme,
      ConstructorDeclaration n => n.name?.lexeme ?? '(new)',
      FunctionDeclaration n
          when n.functionExpression.body is! EmptyFunctionBody =>
        n.name.lexeme,
      FunctionExpression n when n.parent is! FunctionDeclaration =>
        '(closure@${line(n.offset)})',
      _ => null,
    };
    if (rowName != null) {
      final start = line(
        node is AnnotatedNode
            ? node.firstTokenAfterCommentAndMetadata.offset
            : node.offset,
      );
      final end = line(node.end - 1);
      final name = owner.isEmpty ? rowName : '$owner.$rowName';
      final scope = _Scope(end - start + 1);
      for (final child in node.childEntities.whereType<AstNode>()) {
        if (child is! Annotation) walk(child, scope, 0, name);
      }
      rows.add({
        'path': path,
        'name': name,
        'line': start,
        'lines': scope.lines,
        'complexity': scope.branches + 1,
        'branches': scope.branches,
        'nesting': scope.nesting,
        'decisions': scope.counts,
      });
      return;
    }
    final decision = switch (node) {
      IfStatement() || IfElement() => 'if',
      ForStatement() ||
      ForElement() ||
      WhileStatement() ||
      DoStatement() => 'loop',
      ConditionalExpression() => 'conditional',
      CatchClause() => 'catch',
      SwitchCase() || SwitchPatternCase() || SwitchExpressionCase() => 'case',
      WhenClause() => 'when',
      BinaryExpression n when ['&&', '||', '??'].contains(n.operator.lexeme) =>
        n.operator.lexeme,
      _ => null,
    };
    if (active != null && decision != null) {
      active.branches++;
      active.counts.update(decision, (c) => c + 1, ifAbsent: () => 1);
    }
    final isControl =
        node is IfStatement ||
        node is IfElement ||
        node is ForStatement ||
        node is ForElement ||
        node is WhileStatement ||
        node is DoStatement ||
        node is ConditionalExpression ||
        node is CatchClause ||
        node is SwitchStatement ||
        node is SwitchExpression;
    final level = depth + (isControl ? 1 : 0);
    if (active != null && level > active.nesting) active.nesting = level;
    for (final child in node.childEntities.whereType<AstNode>()) {
      walk(child, active, level, owner);
    }
  }
}

String groupFor(String path) {
  final parts = path.split('/');
  if (parts.first == 'vendor') return 'vendor';
  if (parts.any(
    const {'test', 'tests', 'integration_test', 'test_driver'}.contains,
  ))
    return 'tests';
  if (const {'tool', 'tools', 'scripts'}.contains(parts.first))
    return 'tooling';
  return 'product';
}

class Measurement {
  final files = <Map<String, dynamic>>[];
  final functions = <Map<String, dynamic>>[];
  final diagnostics = <Map<String, dynamic>>[];

  void invalid(String path, String message) {
    diagnostics.add({'path': path, 'message': message});
    files.add({'path': path, 'group': groupFor(path), 'parsed': false});
  }

  void measure(String path, String source) {
    final result = parseString(
      content: source,
      path: path,
      throwIfDiagnostics: false,
    );
    final clean = result.errors.isEmpty;
    final start = functions.length;
    if (clean) {
      _Scanner(path, result.lineInfo, functions).walk(result.unit, null, 0, '');
    } else {
      for (final error in result.errors) {
        diagnostics.add({
          'path': path,
          'line': result.lineInfo.getLocation(error.offset).lineNumber,
          'message': error.message,
        });
      }
    }
    files.add({
      'path': path,
      'group': groupFor(path),
      'parsed': clean,
      'lines': LineSplitter.split(source).length,
      'functions': functions.length - start,
    });
  }

  Map<String, dynamic> groupSummary(String group) {
    final matching = files.where((file) => file['group'] == group);
    final scopes = functions.where((f) => groupFor(f['path']) == group);
    return {
      'tracked': matching.length,
      'parsed': matching.where((f) => f['parsed'] == true).length,
      'scopes': scopes.length,
      'complexityAtLeast20': scopes.where((f) => f['complexity'] >= 20).length,
      'complexityAtLeast40': scopes.where((f) => f['complexity'] >= 40).length,
      'nestingAtLeast5': scopes.where((f) => f['nesting'] >= 5).length,
      'spanOver100': scopes.where((f) => f['lines'] > 100).length,
    };
  }

  List<Map<String, dynamic>> ranked(String group, String metric, int limit) {
    final scopes = functions
        .where((f) => groupFor(f['path']) == group)
        .toList();
    scopes.sort((a, b) {
      for (final key in {metric, 'complexity', 'nesting', 'lines'}) {
        final order = (b[key] as int).compareTo(a[key] as int);
        if (order != 0) return order;
      }
      final byPath = (a['path'] as String).compareTo(b['path'] as String);
      return byPath != 0
          ? byPath
          : (a['line'] as int).compareTo(b['line'] as int);
    });
    return scopes.take(limit).toList();
  }
}
