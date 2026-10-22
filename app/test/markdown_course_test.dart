import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/text_tools.dart';
import 'package:handwriting_app/utils/latex.dart';

void main() {
  test('程序课代码只移除 Markdown 包装并保留空行和运算符', () {
    const body = '#include <stdio.h>\nint *p;\n\n---\nvector<T> value;';
    expect(cleanMarkdown('```cpp\n$body\n```'), body);
    expect(
      cleanMarkdown('程序 `*p` 和 ``a`b`` 与 `**literal**`'),
      '程序 *p 和 a`b 与 **literal**',
    );
    expect(cleanMarkdown('  ~~~c\n  #include <T>\n  ~~~~'), '#include <T>');
    expect(cleanMarkdown(r'$\text{`literal`}+x$'), r'$\text{`literal`}+x$');
  });
  test('正文保留比较式和泛型，链接中的括号不残留', () {
    expect(
      cleanMarkdown('a<b 且 c>d；vector<T>\n[控制](https://x/Control_(theory))'),
      'a<b 且 c>d；vector<T>\n控制',
    );
    expect(cleanMarkdown('> > **结论**\n<p>正常</p>'), '结论\n正常');
    final malformed = List.filled(10000, '[a](').join();
    expect(cleanMarkdown(malformed), malformed);
  });
  test('表格去行内样式与链接，代码星号和特殊 TeX 字符保真', () {
    final text = cleanMarkdown(
      '| **元件** | [名称](https://x/R_(c)) |\n| --- | --- |\n| *电阻* | `*p` |\n| `50%` | `\$x\$` |',
    );
    expect(text, contains(r'\text{元件} & \text{名称}'));
    expect(text, contains(r'\text{电阻} & \text{*p}'));
    expect(text, contains(r'\text{50\%} & \text{\$x\$}'));
    expect(convertLatex(text), contains('元件'));
    expect(convertLatex(text), isNot(contains(r'\begin')));
  });
}
