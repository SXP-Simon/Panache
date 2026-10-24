import 'latex.dart';
import 'text_tools.dart';

/// Prepare pasted Markdown and math in a fixed order without interpreting code.
String prepareHandwritingText(
  String source, {
  String tableMode = 'latex',
  bool english = false,
}) => cleanMarkdown(
  source,
  tableMode: tableMode,
  english: english,
  transformMath: convertLatex,
);
