/**
 * Markdown 标记清洗与纯文本提取工具模块
 * 用于将用户复制/导入的 Markdown 内容（标题、加粗、斜体、引用、链接、代码块、表格等）
 * 清洗转换为适合手写排版的纯文本内容，同时保留分页标记（---）与段落结构。
 */

/**
 * 表格清洗格式化处理函数
 * @param {string[]} tableLines 属于同一个表格的一组原始行
 * @param {'list'|'aligned'|'raw_pipe'|'clean'} mode 处理模式
 *  - 'list': 结构化清单展开模式（推荐抄写/笔记：【表头】项1: 值1，项2: 值2）
 *  - 'aligned': 纯净对齐文本模式（剔除竖线，利用空格保持整齐排列）
 *  - 'raw_pipe': 传统竖线分隔模式（列1 | 列2）
 *  - 'clean': 彻底清除表格结构线，平铺内容
 * @returns {string[]}
 */
export function formatMarkdownTable(tableLines, mode = 'list') {
  if (!tableLines || tableLines.length === 0) return [];

  const parsedRows = [];
  for (const line of tableLines) {
    // 忽略 Markdown 表格分隔线（如 |---|:---:|---:|）
    if (/^[ \t]*\|?(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*:?-+:?[ \t]*\|?[ \t]*$/.test(line)) {
      continue;
    }
    // 提取单元格文本
    const rowContent = line
      .replace(/^[ \t]*\|/, '')
      .replace(/\|[ \t]*$/, '');
    const cells = rowContent.split('|').map(c => c.trim());
    if (cells.some(c => c.length > 0)) {
      parsedRows.push(cells);
    }
  }

  if (parsedRows.length === 0) return [];
  if (parsedRows.length === 1 || mode === 'clean') {
    return parsedRows.map(row => row.join('  '));
  }

  const headers = parsedRows[0];
  const dataRows = parsedRows.slice(1);

  if (mode === 'list') {
    // 结构化清单展开：符合手写笔记习惯，不使用印刷体粗黑中括号【】
    // 格式如：1. 项名 (列1: 值1; 列2: 值2) 或直接自然短语
    return dataRows.map((row, rowIndex) => {
      const primaryVal = row[0] || (rowIndex + 1);
      const otherFields = [];
      for (let i = 1; i < Math.max(headers.length, row.length); i++) {
        const headerName = headers[i] || `列${i + 1}`;
        const val = row[i] || '-';
        otherFields.push(`${headerName}: ${val}`);
      }
      const prefix = `${rowIndex + 1}. ${headers[0] || '项'}: ${primaryVal}`;
      return otherFields.length > 0
        ? `${prefix} (${otherFields.join('; ')})`
        : prefix;
    });
  }

  if (mode === 'aligned') {
    // 空格对齐模式：计算每列在东亚字符宽度下的最大宽度，用全角/半角空格填充
    const colCount = Math.max(...parsedRows.map(r => r.length));
    const colWidths = new Array(colCount).fill(0);

    const getCharWidth = (str) => {
      let width = 0;
      for (let i = 0; i < str.length; i++) {
        // 全角字符与中文字符记为 2，半角记为 1
        width += str.charCodeAt(i) > 255 ? 2 : 1;
      }
      return width;
    };

    parsedRows.forEach(row => {
      row.forEach((cell, colIndex) => {
        colWidths[colIndex] = Math.max(colWidths[colIndex], getCharWidth(cell));
      });
    });

    return parsedRows.map(row => {
      return row.map((cell, colIndex) => {
        const curWidth = getCharWidth(cell);
        const padding = Math.max(0, colWidths[colIndex] - curWidth + 2);
        return cell + ' '.repeat(padding);
      }).join('').trimEnd();
    });
  }

  // 默认为 raw_pipe 模式
  return parsedRows.map(row => row.join(' | '));
}

/**
 * 清洗字符串中的 Markdown 标记，返回适合手写渲染的纯文本
 * @param {string} text 输入的 Markdown 文本
 * @param {Object} [options] 清洗配置项
 * @param {'list'|'aligned'|'raw_pipe'|'clean'} [options.tableMode='list'] 表格处理模式
 * @returns {string} 清洗后的纯文本
 */
export function cleanMarkdown(text, options = {}) {
  if (!text || typeof text !== 'string') {
    return '';
  }

  const tableMode = options.tableMode || 'list';

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

  // 5. 剥离普通外部网页图片与超链接，同时精准保护本地手绘插图（包含 Base64 数据与短占位符 ![插图 1]、![插图 1|50%]）
  // 5.1 暂存受保护的插图标记
  s = s.replace(/!\[([^\]]*)\]\((data:image\/[^;]+;base64,[A-Za-z0-9+/=\s]+|img:[^)]+)\)/g, '<<<INLINE_IMG_START>>>$1<<<INLINE_IMG_MID>>>$2<<<INLINE_IMG_END>>>');
  s = s.replace(/!\[(插图(?:[ \t]*[#:_-]?[ \t]*\d+)?(?:\|[^\]]+)?)\]/g, '<<<SHORT_IMG_START>>>$1<<<SHORT_IMG_END>>>');

  // 5.2 剥离普通外部链接与普通非手绘网页图片：![alt](http://...) -> alt，[text](url) -> text
  s = s.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1');
  s = s.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  s = s.replace(/<([a-zA-Z]+:\/\/[^>]+)>/g, '$1');

  // 5.3 恢复受保护的插图标记
  s = s.replace(/<<<INLINE_IMG_START>>>(.*?)<<<INLINE_IMG_MID>>>(.*?)<<<INLINE_IMG_END>>>/g, '![$1]($2)');
  s = s.replace(/<<<SHORT_IMG_START>>>(.*?)<<<SHORT_IMG_END>>>/g, '![$1]');

  // 6. 处理标题、引用、任务列表与表格
  const lines = s.split('\n');
  const cleanedLines = [];
  let currentTableLines = [];

  const flushTable = () => {
    if (currentTableLines.length > 0) {
      const formatted = formatMarkdownTable(currentTableLines, tableMode);
      cleanedLines.push(...formatted);
      currentTableLines = [];
    }
  };

  const isTableRow = (line) => {
    return /^[ \t]*\|.*\|[ \t]*$/.test(line) ||
      /^[ \t]*\|?(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*:?-+:?[ \t]*\|?[ \t]*$/.test(line);
  };

  for (let line of lines) {
    if (isTableRow(line)) {
      currentTableLines.push(line);
      continue;
    } else {
      flushTable();
    }

    // 6.1 剥离 Markdown 标题开头的 # 符号：# 标题 -> 标题
    line = line.replace(/^[ \t]*#{1,6}[ \t]+/, '');

    // 6.2 剥离引用前缀 > 符号：> 引用内容 -> 引用内容
    line = line.replace(/^[ \t]*>+[ \t]?/, '');

    // 6.3 剥离任务列表标记：- [ ] 待办 / - [x] 已办 -> 待办
    line = line.replace(/^([ \t]*[-*+])[ \t]+\[[ xX]\][ \t]+/, '$1 ');

    // 6.4 剥离无序列表前缀符（如 `- 项`、`* 项`、`+ 项`），转换为自然手写文本（人类手写通常不保留印刷体短横线）
    // 注意：保留行首用于数学负号或减号的情形（例如 -0.5 或 -x-x̄），仅当短横线后跟随空格时作为列表符剥离
    line = line.replace(/^([ \t]*)[-*+][ \t]+/, '$1');

    // 6.5 保留独立分页标记 ---，其余形式的分隔线规范化为 ---
    if (/^[ \t]*([*_-][ \t]*){3,}[ \t]*$/.test(line)) {
      line = '---';
    }

    cleanedLines.push(line);
  }
  flushTable();

  s = cleanedLines.join('\n');

  // 7. 剥离加粗、斜体、删除线、高亮等行内装饰符
  // 粗斜体 ***text*** 或 ___text___
  s = s.replace(/\*\*\*([^\s*](?:[\s\S]*?[^\s*])?)\*\*\*/g, '$1');
  s = s.replace(/___([^\s_](?:[\s\S]*?[^\s_])?)___/g, '$1');

  // 加粗 **text** 或 __text__
  s = s.replace(/\*\*([^\s*](?:[\s\S]*?[^\s*])?)\*\*/g, '$1');
  s = s.replace(/__([^\s_](?:[\s\S]*?[^\s_])?)__/g, '$1');

  // 删除线 ~~text~~ 与高亮 ==text==
  s = s.replace(/~~([^\s~](?:[\s\S]*?[^\s~])?)~~/g, '$1');
  s = s.replace(/==([^\s=](?:[\s\S]*?[^\s=])?)==/g, '$1');

  // 单星号斜体 *text*（遵循 CommonMark 左/右定界符约束：星号内侧紧跟非空白，且排除算术乘号两端留空如 3 * 5）
  // 匹配前瞻/后顾必须确保边界是非星号非空白字符，且避免孤立的乘号
  s = s.replace(/(^|[^\w*])\*([^\s*](?:[^*\n]*?[^\s*])?)\*(?=[^\w*]|$)/gu, '$1$2');

  // 单下划线斜体 _text_（避免误伤数学下标如 x_1，仅在两侧有非字母下划线或边界时清洗）
  s = s.replace(/(^|[^\w_])_([^\s_](?:[^_\n]*?[^\s_])?)_(?=[^\w_]|$)/gu, '$1$2');

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
