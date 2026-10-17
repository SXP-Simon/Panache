import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/text_tools.dart';
import 'package:handwriting_app/utils/latex.dart';
import 'package:handwriting_app/models/settings.dart';

void main() {
  test('清洗代码围栏保留字面正文但移除语言标记', () {
    for (final fence in ['```', '~~~~']) {
      final source =
          '标题\n${fence}text\n**字面文本**\n'
          r'\frac{a}{b}'
          '\n$fence\n结尾';
      expect(
        cleanMarkdown(source),
        '标题\n**字面文本**\n'
        r'\frac{a}{b}'
        '\n结尾',
      );
    }
  });
  test('Markdown 清洗保护插图、右对齐和数学运算并移除分页空行', () {
    expect(
      cleanMarkdown('# 标题\n**正文**\n\n---\n>>>署名\n![插图 1|50%]\n3 * 5'),
      '标题\n正文\n>>>署名\n![插图 1|50%]\n3 * 5',
    );
    expect(
      cleanMarkdown('| 项目 | 数量 |\n| --- | --- |\n| 苹果 | 2 |'),
      '1. 项目: 苹果 (数量: 2)',
    );
  });
  test('清洗去掉空白行与标准化分隔符但保留行内横线', () {
    final cleaned = cleanMarkdown(
      '\r\n---\r\n \t\r\n甲\r\n\t---  \r\n***\r\n___\r\n<hr/>\r\n乙 --- 丙\r\n\r\n',
    );
    expect(cleaned, '甲\n乙 --- 丙');
    expect(cleanMarkdown(cleaned), cleaned);
    expect(cleanMarkdown('\n \t\n---\n'), '');
  });
  test('起首分页包围普通正文不能当作YAML元数据删除', () {
    expect(cleanMarkdown('---\n第一段正文\n---\n第二段正文'), '第一段正文\n第二段正文');
    expect(cleanMarkdown('---\ntitle: Notes\nauthor: Simon\n---\n正文'), '正文');
    expect(cleanMarkdown('---\ntitle: Notes\n---'), '');
  });
  test('插图折叠与展开保留比例和字节', () {
    final images = <String, String>{};
    final text = collapseImages('![图|75%](data:image/png;base64,YQ==)', images);
    expect(text, '![插图 1|75%]');
    expect(
      expandImages(text, images),
      '\n![插图 1|75%](data:image/png;base64,YQ==)\n',
    );
    expect(
      collapseImages('![图](data:image/png;base64,YQ==)', images),
      '![插图 1]',
    );
  });
  test('书信缩进、分页与落款', () {
    expect(
      formatLetter('亲爱的朋友：\n正文\n---\n>>>旧落款', '张三', '2026年10月12日'),
      '亲爱的朋友：\n　　正文\n---\n>>>旧落款\n>>>张三\n>>>2026年10月12日',
    );
  });
  test('LaTeX 常用符号、嵌套公式、矩阵、上下标', () {
    expect(
      convertLatex(r'$\sqrt{x}+\frac{a}{b}\Rightarrow\beta$'),
      '√(x)+(a)/(b)⇒β',
    );
    expect(convertLatex(r'\boxed{\boxed{x_1}}'), 'x₁');
    expect(convertLatex(r'\begin{aligned}x&=1\\y&=2\end{aligned}'), 'x=1\ny=2');
    expect(
      convertLatex(r'\begin{pmatrix}1 & 2 \\ 3 & 4\end{pmatrix}'),
      '( 1  2 ; 3  4 )',
    );
    expect(convertLatex(r'$\frac{1}{2}+\Bigl\{p\Bigr\}$'), '½+{p}');
  });
  test('旧版草稿参数、浮点归一化与落款识别', () {
    final settings = Settings();
    settings.restore({
      'fontSize': 70.0,
      'marginLeft': 150,
      'isUnderlined': true,
    });
    expect(settings.values['font_size'], '70');
    expect(settings.values['left_margin'], '150');
    expect(settings.valid, isTrue);
    settings.values['width'] = '420';
    settings.smallPreset();
    expect(settings.values['width'], '2481');
    expect(settings.values['font_size'], '70');
    settings.values['font_size'] = '70.5';
    expect(settings.valid, isFalse);
    final ending = extractLetterEnding('第一段。\n第二段。\n张三\n2026年7月26日');
    expect(ending, (body: '第一段。\n第二段。', signature: '张三', date: '2026年7月26日'));
    expect(cleanMarkdown('![网站图](https://example.com/a.png)'), '网站图');
  });
  test('非法参数不提交，预设保留全部字段', () {
    final settings = Settings();
    expect(settings.valid, isTrue);
    settings.values['strikethrough_probability'] = '2';
    expect(settings.valid, isFalse);
    settings.values['strikethrough_probability'] = '0';
    settings.values['width'] = '20';
    expect(settings.valid, isFalse);
  });
}
