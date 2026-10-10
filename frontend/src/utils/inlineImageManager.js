/**
 * 行内手写插图管理与短占位符转换模块 (Inline Image Manager)
 * 
 * 1. 将大型 Base64 字符串折叠为轻量可读的短占位符（如 `![插图 1]`），彻底消除 Textarea 卡顿与视觉混乱；
 * 2. 在提交生成或预览时，无缝将短占位符展开还原为真实 Base64 Markdown 标记；
 * 3. 配合 cleanMarkdown 实现插图保护，防止格式清洗误杀插图。
 */

/**
 * 将文本中的超长 Base64 插图标记折叠提取为轻量短占位符
 * @param {string} text 原始文本
 * @param {Object.<string, string>} existingStore 现有的图片映射字典 { id: base64Data }
 * @returns {{ collapsedText: string, imageStore: Object.<string, string>, imageList: Array<{ id: string, index: number, alt: string, data: string }> }}
 */
export function collapseInlineImages(text, existingStore = {}) {
  if (!text || typeof text !== 'string') {
    return { collapsedText: '', imageStore: { ...existingStore }, imageList: [] };
  }

  const imageStore = { ...existingStore };
  let counter = Object.keys(imageStore).length;

  // 正则匹配 ![alt](data:image/...;base64,...) 或 ![alt|scale](data:...)
  const base64ImgRegex = /!\[([^\]]*)\]\((data:image\/[^;]+;base64,[A-Za-z0-9+/=\s]+)\)/g;

  const collapsedText = text.replace(base64ImgRegex, (match, alt, base64Data) => {
    // 检查是否已经在 store 中
    let foundId = null;
    for (const [id, data] of Object.entries(imageStore)) {
      if (data.trim() === base64Data.trim()) {
        foundId = id;
        break;
      }
    }

    if (!foundId) {
      counter += 1;
      foundId = `img_${counter}`;
      imageStore[foundId] = base64Data.trim();
    }

    const indexMatch = foundId.match(/\d+/);
    const indexNum = indexMatch ? parseInt(indexMatch[0], 10) : counter;
    
    // 如果 alt 中携带了 |50% 等参数，予以提取
    let scaleSuffix = '';
    let baseAlt = alt ? alt.trim() : '';
    if (baseAlt.includes('|')) {
      const parts = baseAlt.split('|');
      baseAlt = parts[0].trim();
      scaleSuffix = `|${parts[1].trim()}`;
    }
    // 统一以 "插图 <index>" 为标准标记，便于双向索引与跨组件管理
    const cleanAlt = `插图 ${indexNum}${scaleSuffix}`;

    return `![${cleanAlt}]`;
  });

  return {
    collapsedText,
    imageStore,
    imageList: getReferencedImages(collapsedText, imageStore)
  };
}

/**
 * 将文本中的短占位符展开还原为完整的 Base64 图片 Markdown 标记
 * @param {string} text 包含短占位符的文本
 * @param {Object.<string, string>} imageStore 图片字典 { id: base64Data }
 * @returns {string} 展开后的完整 Markdown 文本
 */
export function expandInlineImages(text, imageStore = {}) {
  if (!text || typeof text !== 'string') {
    return '';
  }
  if (!imageStore || Object.keys(imageStore).length === 0) {
    return text;
  }

  // 1. 替换形如 ![插图 1]、![插图: 1]、![插图 1|50%] 等
  let result = text.replace(/!\[(插图[ \t]*[#:_-]?[ \t]*(\d+)(?:\|[^\]]+)?)\]/g, (match, fullAlt, numStr) => {
    const id = `img_${numStr}`;
    const base64Data = imageStore[id] || imageStore[numStr];
    if (base64Data) {
      return `\n![${fullAlt}](${base64Data})\n`;
    }
    return match;
  });

  // 2. 替换形如 ![插图](img:1) 或 ![alt|50%](img_1)
  result = result.replace(/!\[([^\]]*)\]\(img:?_?(\d+)\)/g, (match, alt, numStr) => {
    const id = `img_${numStr}`;
    const base64Data = imageStore[id] || imageStore[numStr];
    if (base64Data) {
      return `\n![${alt || '插图'}](${base64Data})\n`;
    }
    return match;
  });

  return result;
}

/**
 * 获取当前文本中正在引用的图片列表
 * @param {string} text 文本内容
 * @param {Object.<string, string>} imageStore 图片映射字典
 * @returns {Array<{ id: string, index: number, alt: string, scale: string, data: string }>}
 */
export function getReferencedImages(text, imageStore = {}) {
  if (!text || !imageStore) return [];
  const list = [];
  // 匹配 ![插图 1]、![插图 1|50%]、![插图: 1|75%]
  const regex = /!\[(?:插图[ \t]*[#:_-]?[ \t]*(\d+)(?:\|([^\]]+))?|([^\]]*)\(img:?_?(\d+)\))\]/g;
  let m;
  while ((m = regex.exec(text)) !== null) {
    const num = m[1] || m[4];
    const scaleStr = (m[2] ? m[2].trim() : '') || '100%';
    if (num) {
      const id = `img_${num}`;
      if (imageStore[id] && !list.some(item => item.id === id)) {
        list.push({
          id,
          index: parseInt(num, 10),
          alt: `插图 ${num}`,
          scale: scaleStr,
          data: imageStore[id]
        });
      }
    }
  }
  return list;
}
