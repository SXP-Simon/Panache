/**
 * Markdown 标记清洗与纯文本提取工具模块
 * 用于将用户复制/导入的 Markdown 内容（标题、加粗、斜体、引用、链接、代码块、表格等）
 * 清洗转换为适合手写排版的纯文本内容，同时保留分页标记（---）与段落结构。
 */

/**
 * 清洗字符串中的 Markdown 标记，返回适合手写渲染的纯文本
 * @param {string} text 输入的 Markdown 文本
 * @returns {string} 清洗后的纯文本
 */
export function cleanMarkdown(text) {
  if (!text || typeof text !== 'string') {
    return '';
  }

  let s = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');

  // 1. 移除文档顶部的 YAML / TOML Front Matter
  s = s.replace(/^---[ \t]*\n[\s\S]*?\n---[ \t]*\n?/, '');

  // 2. 移除 HTML 注释与转换常见 HTML 换行
  s = s.replace(/<!--[\s\S]*?-->/g, '');
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<hr\s*\/?>/gi, '\n---\n');
  s = s.replace(/<\/?[a-zA-Z][^>]*>/g, '');

  // 3. 剥离多行代码块（保留代码内部纯文本）
  s = s.replace(/```[^\n]*\n([\s\S]*?)```/g, '$1');
  s = s.replace(/~~~[^\n]*\n([\s\S]*?)~~~/g, '$1');

  // 4. 剥离行内代码反引号 `code` -> code
  s = s.replace(/`([^`\n]+)`/g, '$1');

  // 5. 剥离图片与超链接：![alt](url) -> alt，[text](url) -> text
  s = s.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1');
  s = s.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  s = s.replace(/<([a-zA-Z]+:\/\/[^>]+)>/g, '$1');

  // 6. 处理标题、引用、任务列表与表格行
  const lines = s.split('\n');
  const cleanedLines = [];

  for (let line of lines) {
    // 6.1 剥离 Markdown 标题开头的 # 符号：# 标题 -> 标题
    line = line.replace(/^[ \t]*#{1,6}[ \t]+/, '');

    // 6.2 剥离引用前缀 > 符号：> 引用内容 -> 引用内容
    line = line.replace(/^[ \t]*>+[ \t]?/, '');

    // 6.3 剥离任务列表标记：- [ ] 待办 / - [x] 已办 -> - 待办
    line = line.replace(/^([ \t]*[-*+])[ \t]+\[[ xX]\][ \t]+/, '$1 ');

    // 6.4 过滤 Markdown 表格分隔线（如 |---|---| 或 |:---:|---:|）
    if (/^[ \t]*\|?(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*:?-+:?[ \t]*\|?[ \t]*$/.test(line)) {
      continue;
    }

    // 6.5 规范化 Markdown 表格内容行：| 列1 | 列2 | -> 列1 | 列2
    if (/^[ \t]*\|.*\|[ \t]*$/.test(line)) {
      const cells = line
        .replace(/^[ \t]*\|/, '')
        .replace(/\|[ \t]*$/, '')
        .split('|')
        .map(c => c.trim());
      line = cells.join(' | ');
    }

    // 6.6 保留独立分页标记 ---，其余形式的分隔线规范化为 ---
    if (/^[ \t]*([*_-][ \t]*){3,}[ \t]*$/.test(line)) {
      line = '---';
    }

    cleanedLines.push(line);
  }

  s = cleanedLines.join('\n');

  // 7. 剥离加粗、斜体、删除线、高亮等行内装饰符
  // 粗斜体 ***text*** 或 ___text___
  s = s.replace(/\*\*\*(.*?)\*\*\*/g, '$1');
  s = s.replace(/___(.*?)___/g, '$1');

  // 加粗 **text** 或 __text__
  s = s.replace(/\*\*(.*?)\*\*/g, '$1');
  s = s.replace(/__(.*?)__/g, '$1');

  // 删除线 ~~text~~ 与高亮 ==text==
  s = s.replace(/~~(.*?)~~/g, '$1');
  s = s.replace(/==(.*?)==/g, '$1');

  // 单星号斜体 *text*
  s = s.replace(/\*([^*\n]+)\*/g, '$1');

  // 单下划线斜体 _text_（避免误伤数学下标如 x_1，仅在两侧有空格或标点时清洗）
  s = s.replace(/(^|[\s\p{P}])_([^_ \n]+)_(?=[\s\p{P}]|$)/gu, '$1$2');

  // 8. 收敛连续过多的空行（最多保留 1 个空行分隔段落）
  s = s.replace(/\n{3,}/g, '\n\n');

  // 9. 去除每行行尾多余的无意义空格
  s = s
    .split('\n')
    .map(l => l.replace(/[ \t]+$/, ''))
    .join('\n');

  return s.trim();
}

/**
 * 判断文本中是否包含 Markdown 标记语法
 * @param {string} text
 * @returns {boolean}
 */
export function hasMarkdownMarkup(text) {
  if (!text || typeof text !== 'string') return false;
  return /(?:^[ \t]*#{1,6}[ \t]+|(?:\*\*|__)[^\n]+(?:\*\*|__)|(?:\*|_)[^\n]+(?:\*|_)|~~[^\n]+~~|!\[[^\]]*\]\([^)]*\)|\[[^\]]+\]\([^)]*\)|```|`[^`\n]+`|^[ \t]*>+[ \t]?|^[ \t]*\|.*\|[ \t]*$)/m.test(
    text
  );
}
