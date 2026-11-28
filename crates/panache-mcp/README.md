# Panache 本地 MCP

通过支持 stdio 的 MCP 客户端把 Markdown 作业或诗稿排成手写页。文字整理使用工作台的 Markdown、LaTeX 和表格转换器。预览和导出都在本机调用同一个 Rust 引擎。

## 在桌面版连接 AI 客户端

1. 完整解压或安装桌面版，在「应用设置 → 连接 AI 客户端」复制本机配置。
2. 在支持**本地 stdio 服务**的 AI 客户端中注册名为 `panache` 的服务。使用 `mcpServers` 格式的 JSON 配置可直接合并其中的 `panache` 条目，保留已有服务。若客户端使用表单、TOML 或其他格式，按其格式填入复制结果中的 `command` 和可选的 `args`。程序路径填作一项，每个参数各占一项。
3. 在客户端重新加载 MCP 配置或重新连接，问它「请调用 Panache 列出可用字体」。收到本机的字体文件名就表示连接成功。若客户端只接受服务器网址，请选择能在本机启动 stdio 程序的客户端。

**连不上时，先看卡在哪一步。** 如果桌面版一打开就提示「内置手写引擎无法运行」，这是进入设置前的启动问题，和是否在 AI 客户端填写了配置无关。记下 Panache 版本和系统版本。若配置已复制，但 AI 客户端没有收到 Panache 工具返回的字体名，请查看客户端的 MCP 启动日志。若提示找不到文件，从当前安装重新复制配置；若提示系统库版本不匹配，请记下完整错误，改 JSON 不会解决。

客户端通过标准输入输出启动 Panache，关闭工作台后也能使用。移动安装目录后可重新复制。

桌面包包含 MCP、字体和 Markdown 转换器，JavaScript 运行时已编入 MCP 程序。Windows 新安装使用根目录启动器，可自动跟随应用更新；从旧启动器升级的安装会使用当前版本的 MCP 路径，更新后请重新复制。

macOS 请先将 Panache.app 移到长期使用的位置，Linux 请先完整解压并保留可执行权限，然后再复制配置。工作台正常启动时只启动自己的渲染后端。MCP 在 AI 客户端连接时启动，关闭连接即退出。Android 和 iOS 使用进程内的手写引擎，移动版没有供其他应用调用的 MCP 入口。

同一次整稿导出可以跨节复用字体。一次预览或导出结束后会释放已解析的大字体，最近四页预览仍可直接取回。下一次生成未缓存的页面时会重新加载所需字体。

如果替换了已配置的字体文件，需要立即看新成图，请在 `preview_handwriting` 的默认或 `view=image` 请求中传 `fresh: true`。它会重新渲染所请求的一页，不改稿件版本、不登记复查；重绘失败会返回错误并清掉这一页的旧缓存。加入新字体名仍需重新连接。

## 从源码构建

在仓库根目录运行以下命令。构建需要项目指定的 Rust、Flutter 和 Python。

```sh
python scripts/build-text-worker.py
cargo build --locked --release -p panache-mcp
```

将以下条目加入 MCP 客户端配置，把示例路径换成本机绝对路径。Windows 的可执行文件名为 `panache-mcp.exe`。

```json
{
  "mcpServers": {
    "panache": {
      "command": "/absolute/path/to/target/release/panache-mcp",
      "env": {
        "PANACHE_MCP_HOME": "/absolute/path/to/my-manuscripts"
      }
    }
  }
}
```

开发构建从仓库读取字体和生成的 `app/web/prepare-text-worker.js`。移动可执行文件时，可将 `font_assets/` 和 `prepare-text-worker.js` 放在程序旁，或用 `PANACHE_FONT_DIR`、`PANACHE_MARKDOWN_WORKER` 指定位置。字体保留各自的[许可记录](../../assets/licenses/FONT-LICENSES.md)。

## 写稿、预览和复查

只有一句「帮我做一份手写作业」时，先贴要写的内容。想打印，就用普通纸样做 PDF；想填在老师发的练习纸上，就用那张纸的照片；想把字放进海报，就用透明字迹，解开 ZIP 后取出 PNG。已经说清「用这段话做打印版」就可以直接开始。

可以先说「用这段话给我看第一页」，看过后说「字大一点」，再说「就用这一版」。客户端按同一稿件的版本号取预览和导出。查看小样使用 `preview_handwriting(view="image")`，无需创建检查单。

表格下方的正文会按实际倾斜后的表框避让。整页复查发现表格末行与下方文字可能连在一起时，`preview_handwriting(view="review")` 会在同一次响应里给出 `table_clearance_check` 和原尺寸局部图。直接读末行和后面的文字即可判断是否需要调整间距。

试验性的 `replace_section_text` 可按当前稿件版本替换已有节中的一整行，无需重传节内图片。整节的各块须用空行分隔，每块须为单行正文或已验证的独立内嵌图片。默认模式下，所有正文行只允许字母（含汉字）、数字和行内普通半角空格。即使只想改「春天」，另一段的「踏青真好。」也会因含句号触发下面的重试提示。

旧值与新值须不同，默认各为 1–160 个字符。旧值须独占一行，并且在整节原文中只出现一次。例如，另一行的「初春天气」也含有「春天」，替换就会因匹配有歧义而被拒绝。目标节已有保存的手摆字形调整时也会拒绝。创建、追加或修改其他复杂内容可用 `save_section` 传完整原文；对已有节的小改字先尝试快捷替换，它会先检查当前正文有没有保存过手摆。

遇到普通标点或长行时，按回执原样重试 `replace_section_text`，加上 `retry_plain=true`。服务直接使用已存原稿，核对处理后的全文只变了目标行、内嵌图片数据完全一致后才保存。重试仍要求唯一的完整独立段、相同版本和引擎字数上限；支持的额外字符是 `，。！？；：、（）“”‘’,.!?;:()`。复杂标记、找不到的文字或目标有歧义时，保留原稿并核对具体位置。

遇到手摆保护时，先告诉用户文字尚未修改、位置仍在原版。整节保存会重新排版，新版不会自动继承手摆。让用户选择保留现版，或允许重新排版后看预览。用户要求保持原位时，不能仅凭旧字形编号或相同的移动距离就声称位置已经恢复。明确同意重新排版后，可以按同一版本读全原文、保留其余内容，用相同版本号调用 `save_section` 并预览新版。若无法确保图片等内容能完整重存，应先告诉用户并保留原稿。

写作业时，客户端可直接传 `{"markdown":"第一题","style":{"homework":true}}`。纯文字、预设纸和照片底纸共用作业默认值：优先使用随包的李国夫手写体，字的大小和倾斜有轻微变化。指定字体会优先使用；想让字更整齐可加 `"relaxed_handwriting":false`。同一稿件的随机种子随稿保存。

稿件会原样保存嵌入的图片，正文里的插图会画成手绘线稿，无法保留原彩。颜色很重要时，请先看这一页的小样，别把插图改成整页底纸。

使用自己的纸张时，在第一次调用 `save_section` 时传入 `paper_path`，例如 `{"markdown":"第一题","paper_path":"C:/作业/南昌大学横线纸.jpg"}`。路径指向运行 MCP 的电脑上的图片。默认保留原照片，按识别到的横线投影字迹和插图。`paper` 返回排版尺寸、边距、行距、识线结果，投影时另有原照尺寸。可用 `preview_handwriting(view="paper")` 单独看底纸，或在导入时通过 `paper_guides` 指定参考线。需要校平底纸时传 `paper_mode="flatten"`。无可靠横线时保留底图，使用普通行距。纸张随稿件保存一次，后续追加、回查、预览和导出可在原图移动后继续使用。

如果照片是聊天附件，先用客户端支持的文件传送功能，把照片交给 Panache。云端没有这项功能时，可在照片所在电脑连接桌面版再使用。复制手机或另一台电脑上的路径不能传照片。带视觉能力的模型可以查看客户端转交的预览图。客户端或模型只能处理文字时，可读取版面和像素测量，并请用户打开导出文件确认外观，再按反馈修改。

| 工具 | 用法 |
| --- | --- |
| `list_fonts` | 按名称、文件名或来源（`bundled`、`user`、`system`）检索字体。默认 20 项，使用 `next_offset` 翻页。传入 `sample` 可在稿件的纸张上比较当前字体和一至两个候选字体。 |
| `save_section` | 用 `markdown` 新建稿件。首次可传标题、字体、字号、纸样、墨色、种子和作业排版模式。返回 `draft_id`、版本号和节号。 |
| `list_drafts` | 找回本地稿件和最新版本。每批 20 条，可传 `offset`。 |
| `read_section` | `summary` 取版本、长度和样式；默认 `excerpt` 隐去正文中已识别的内嵌图片数据；`source` 读取精确 Markdown。后两种视图按字符分页，默认 1000 字，单次最多 4000 字。 |
| `preview_handwriting` | 默认返回首页 PNG。用 `section`、`page` 查看指定节中的一页，两者从 1 开始。 |
| `export_handwriting` | 按节顺序导出整份稿件，返回绝对路径、版本和实际页数。格式可选 `pdf` 或 `zip`，ZIP 从 `0.png` 开始编号。导出结果的 `review.unreviewed_pages` 按打印顺序列出缺少整页复盘的 `section`、`page`。只要求导出并列出缺单页时，直接转述回执。用户要求补验时，再按导出的版本和坐标调用 `preview_handwriting(view="review")` 建单。仅 ZIP 返回 `review.zip_pixels`，与该版各页最近一次整页检查单比对：`pages_matching_latest_review` 计相同页数，`different_pages` 列出像素不同的节内页码，`reviewed_pages_without_digest` 计有单但无摘要的页数。无单的页不参与比对；这些数字不表示用户已看过成品。 |
| `describe_controls` | 调参时可将参数直接放在 `changes` 内，也可写成 `{"changes":{"variation":{"perturb_theta_sigma":0.07}}}`。传 `{}` 列出参数组；只传 `group` 查看参数、单位、范围和枚举值。传 `group` 和 `draft_id` 读取当前保存版的实际值，另带 `revision` 可查指定版。行距和页面几何查 `layout`；底纸参考线校准不在该组。 |
| `tune_handwriting` | 可在原稿上更新参考线、导入本机字体，并一次提交多项全稿参数，如 `{"ink_opacity":85,"word_spacing":2}`。`null` 恢复建稿时的设置。 |
| `storage_usage` | 查询目录和逐稿用量，以及当前预算。 |
| `plan_cleanup` | 按稿列出废弃临时文件和受保护的已交付导出。 |
| `apply_cleanup` | 复核计划，仅清理选中的废弃临时文件。 |
| `annotate_review` | 将用户原话或模型观察挂到指定复盘 ID，保持稿件版本号。 |
| `adjust_glyphs` | 先用 `preview_handwriting(view="layout")` 取编号和坐标，再按同一节、页和版本调整选中字形。 |

若本次只改稿、打印和统计缺单页，可在客户端的 MCP 服务配置中设置 `PANACHE_MCP_PRESERVE_REVIEWS=1`。该连接仍可正常调参、看图和导出，完整检查单与评语会保留原样。

例如用 `list_fonts(query="楷", source="system", limit=8)` 检索系统字体。把 `entries[].id` 用于建稿的 `style.font` 或调稿的 `changes.font`。随包字体继续接受原文件名。个人和系统字体会随稿保存，删除源文件后仍可预览历史版本。TTF、OTF 和 TTC/OTC 中带轮廓、单个字面大小不超过 32 MiB 的字体可供选择。

给照片作业选字时，先用正文中的一行试排，例如“基本块 B1（1～2），if i > 10”。在精修位置前调用 `list_fonts`：

```json
{"sample":{"draft_id":"稿件 ID","revision":1,"fonts":["华阳手写体.ttf","李国夫手写体.ttf"],"crop":[200,300,580,160]}}
```

`crop` 是原图的左、上、宽、高。请替换为稿件实际文字所在位置；省略时比较整页。客户端会收到标有字体的图片。选中候选后使用其 `tune_arguments`。图中标签若由外部程序绘制，应在绘制时采用选定字体。新作业的嵌入图沿用正文笔色、透明度、粗细和柔化；已有稿件可用 `tune_handwriting(changes={"illustration_uses_pen":true}, preserve_local_adjustments=true)` 启用。

桌面与 MCP 共享“我的字体”目录，`list_fonts` 的 `user_dir` 给出绝对路径。Windows 使用 `%LOCALAPPDATA%/Panache/fonts`，macOS 使用 `~/Library/Application Support/Panache/fonts`，Linux 使用 `$XDG_DATA_HOME/Panache/fonts`（默认 `~/.local/share/Panache/fonts`）。可通过 `PANACHE_USER_FONT_DIR` 指定绝对路径。把字体放入后调用 `list_fonts(source="user", refresh=true)`。

面向 AI 客户端的调用示例、披露边界和测量口径见[工具设计](tool-design.md)。

查归属某版、某节、某一页的整页复盘，可用 `read_section(view="review", revision=3, section=2, page=1, draft_id=…)`。返回最近记录在这个位置的测量值、原检查单编号及注明来源的评语。该位置没有记录时返回 `status="no_recorded_review"`；直接按数字页码查单不会排版，也不判断该页是否实际存在。已知检查单编号时仍可按 `review_id` 精确读取。

如果用户问“增加某段话以前，某一节最后那张验过吗”，把新增段落中独有的原文字串传给 `before_text`，目标节传 `section`，页码传 `page="last"`。服务端按当前运行环境重新分页，在该字串首次出现的前一版定位目标节末页，然后查这个页码的检查单。返回的 `before_text_match` 标明新增文字所在节和引入版本，顶层的 `revision`、`section`、`page` 标明查单位置。字串跨节重复或同节删后重加时，结果列出最早两个加入时点及对应的前一版。可查的正文节附有简短开头，便于区分补记所在节和实际要查的节。请用户选择，也可分版回答。按补记或末页查多节稿时需明确待查节号。无匹配或首次建稿就存在时，请核对原文或提供明确版本。末页定位使用该版稿件以及目前可用的字体和版式，不读取历史末页页码，不返回图片，也不会新增检查单。单据的 `revision` 表示受检版本，`filed_at_revision` 表示首次入档时稿件的最新版本。旧库没有保存这一信息的单据返回 `null`。回答“补记前验过吗”时请同时转述 `receipt_summary` 中的时间结论。

`page="last"` 返回的 `page_resolution` 会说明页码来自当前环境重新分页。返回的单据或缺单结论只适用于这次定位出的页码，不能证明那是当时的末页。缺单时，`other_recorded_reviews.entries` 最多列出同一版同一节其他五页最近归档的检查单编号；更多页未列出时 `truncated=true`。这些只是候选原单，最大页码也不一定是当时的末页。知道原单号时用 `read_section(view="review", draft_id=…, review_id=…)`；知道原页码时按原版本、节号和数字页码查单。两种方式都无需重新分页。

可用下列 stdio 回归测试复现外部字体同名替换后的末页定位和原单回查：

```sh
uv run --script crates/panache-mcp/tests/last_page_provenance.py target/release/panache-mcp app/web/prepare-text-worker.js
```

预览的页码在每一节内从 1 开始。翻过一节末页时，错误信息给出这节的实际页数，以及所查版本中下一节的起始页；历史版本已到末节时会提示到此为止。

长作业可以按题组或章节分次传入，每节从新页开始。需要连续排版的段落放在同一节，公式、表格、代码块也应完整放在一节内。追加时带上 `draft_id` 和上次返回的 `expected_revision`；修改已有节时再给出 `section`。另一位客户端抢先保存后，用 `read_section` 复核最新内容再提交。

每次保存只转换这一节，Markdown 原文和整理结果存入本地 SQLite。预览某节第 N 页时，引擎从该节开头排到第 N 页，只编码选中的一页。进程内保留最近生成的四张预览，修改其他节仍可复用。预览和导出传相同的 `revision` 可锁定稿件。种子和样式随稿保存，复现时需使用相同字体和引擎。

整稿上限为整理后 10 万字、200 页。完整导出只在调用导出工具时执行；客户端可以取消，提供进度令牌时可看到已完成页数。ZIP 逐页写盘，PDF 在内存中组装压缩页面后写盘。结果成功后才移入 `exports/`。稿件及历史持续保存在 `PANACHE_MCP_HOME`；Windows 默认是 `%LOCALAPPDATA%/Panache/mcp`，其他系统默认是 `$XDG_DATA_HOME/Panache/mcp` 或 `~/.local/share/Panache/mcp`。

想在聊天里拿到文件时，能处理 MCP 内嵌文件的客户端可在导出时传 `include_file=true`，把收到的 PDF 或 ZIP 作为附件显示给用户。512 KiB 以内的完整文件可以随回复传送。更大的文件仍在运行 Panache 的电脑上；两端共用磁盘时可直接打开返回的路径。聊天客户端给出用户可打开的下载链接时，直接把原链接交给用户；确认已展示附件但没有链接时，告诉用户在聊天附件中取件。`file_transfer.status=included` 表示工具回复带有文件内容。纯文字窗口或尚无客户端确认时，说明文件已导出，并按本机路径给出取件位置；这个路径和内嵌资源 URI 都不能当作下载链接。

## 容量与清理

用 `storage_usage` 查询数据目录内常规文件的长度、数据库及其 WAL/SHM 大小、导出目录和所在卷剩余字节。可传 `draft_id` 查看一稿的正文历史、底纸、字体、逐页证据、评语等内容字节数。文件长度、SQLite 内容长度和磁盘分配量口径不同。跨稿复用同一字体的文件目前仍按稿保存。

管理员可在 MCP 启动环境设置以下无符号整数字节值，默认均未设置。多个 MCP 进程共用一个本地目录时应使用相同配置。

| 环境变量 | 触发行为 |
| --- | --- |
| `PANACHE_MCP_WARN_BYTES` | 目录文件总长度达到阈值时，用量查询返回 `warning=true`。 |
| `PANACHE_MCP_MAX_HOME_BYTES` | 用目录剩余预算控制新的字体、底纸和导出内容。正文、复盘与 SQLite 页、索引、日志仍可增长，这是大文件写入预算。 |
| `PANACHE_MCP_MIN_FREE_BYTES` | 为该磁盘卷保留空间。导入时检查内容长度；导出时按文件增长量检查，包括 ZIP 写入和结尾索引。 |

容量不足时可继续读取稿件、比较历史和查询用量。查询不会改变稿件。导出、导入大文件和执行清理共用同一数据目录的跨进程锁；遇到 busy 可在当前操作结束后重试。

1. 用 `plan_cleanup(draft_id=…)` 只读预览。每页最多 50 条登记，可用 `next_after_id` 继续。成功交付的 PDF/ZIP 列出版本、文件名与字节数，交付路径可能仍有人引用。旧版未登记文件计入目录用量。
2. 只有 `abandoned_temp` 可以交给 `apply_cleanup(plan_id=…, candidate_ids=[…])`。计划限当前服务进程，五分钟有效。工具在执行时复核登记、文件身份、修改时间、大小和任务锁，返回实际移除的文件长度及跳过原因。
3. 若用户要求的释放量大于可安全清理的字节数，报告差额。成功交付的导出、来源不明的文件、正文、历史、纸张、字体和复盘评语均受保护。低磁盘空间不会触发自动淘汰。需要删除已交付成品时，由用户按报告中的具体文件自行处理。

## 照片排版与成品复盘

一道模拟理工科作业，分别用 MCP 排在两张无横线的纸张照片上。点击成稿可查看原尺寸 PNG。

| 斜拍的无横线白纸 | 花影下的白纸 |
| --- | --- |
| [![木桌上的斜拍白纸，手写代码、基本块与流程图沿纸边排列](../../assets/examples/angled-sheet-5ad065421e7c.webp)](https://raw.githubusercontent.com/SXP-Simon/Panache/922b6c7303c6a1d86271e42929bb316eb9c953bb/screenshots/worksheet-lettering/round-7/worksheet.png) | [![花头遮住部分右侧纸边，手写作业与流程图避开花头](../../assets/examples/flower-shadow-a07835481c3a.webp)](https://raw.githubusercontent.com/SXP-Simon/Panache/1aea40070e551868368842392ca349a823d95de0/screenshots/worksheet-lettering/round-8/worksheet.png) |

底图摄影 · [Kaboompics](https://www.pexels.com/photo/empty-paper-sheet-on-wooden-table-4207708/) · [Andrzej Gdula](https://www.pexels.com/photo/white-printer-paper-on-brown-wooden-table-11485123/)

1. 表格、无横线纸和画作均可排字。用户已指定位置或委托选位时，直接按意图排版。落字区有歧义时，简短问“要写在哪个栏，哪些地方留白？”若必填区域在画外，或失焦、遮挡、透视已使它无法定位，建稿前指出具体缺哪一块，请用户补拍该区域或确认只填可见部分。已明确要求只写正文时，直接填写可定位的正文区。
2. 用 `save_section` 导入照片并保留版本号。用 `preview_handwriting(view="review")` 取得同一页的底纸、成品和叠图。整页复查图长边最多 900 像素，像素坐标以返回的 `photo_size` 为准。检查有字区域的横线、页眉、页边和需要保留的图案。
3. 调用 `tune_handwriting(draft_id, expected_revision, paper_guides, note)` 在原照片上重排全文。至少给两条参考线，每条提供行号与左右端点。无横线纸也可以指定想写入的区域。传空数组恢复建稿时的校准。旧版本仍可回看；改写书写区域会重置冲突的边距覆盖，重新排版后需重新选字。
4. 局部改动用 `preview_handwriting(view="layout", region=[[x,y],…])` 圈选字形中心，结果按页分批。把选中的 ID 和这次布局返回的版本交给 `adjust_glyphs`。用户点名要改哪几个字时，按 `ids` 的顺序传 `expected_texts`，例如 `ids=[4,6], expected_texts=["春","雨"]`。任一编号对应的文字不符，整批都不保存；版本冲突时重新查布局并定位。相同的字出现多次时，用上下文或位置区分。纯位置选区和旧客户端可以省略文字核对。同一原始行的文字用 `natural_line={"start":[x0,y0],"end":[x1,y1]}` 沿照片上的书写基线定位。默认保留原字号和字宽，短行留白；超长时可换行或扩大可用范围。多行需要统一缩放时使用相同的 `scale_percent`。`place_center` 平移字块；明确需要铺满四角时用 `target_quad`，回执给出纸面字形中心的最大主次轴伸缩比。局部字形还可分别调倾斜、浓度和笔画。调整后复查新版本。
5. 用 `read_section(view="trajectory")` 回看该稿的近期操作、简短调整理由和按页记录的复盘指标。有下一页时，把 `next_cursor` 作为下一次调用的 `cursor`。把需要人判断的歧义带回当前会话；确定符合用途后导出同一版本。

要核对局部改动，用 `preview_handwriting(view="review", region=…, revision=新版本, compare_revision=旧版本)` 查看同一区域的底纸、改前和改后图。移动字块时还可用 `previous_region` 圈出旧位置。需要保护的文字或页眉可单独圈选复查。区域使用原尺寸成品像素。[局部坐标与测量示例](tool-design.md#局部改动的复查)

在照片上画新的流程图时，把下例直接写入节的 Markdown。节点文字继承稿件的字体，图框和箭头按其笔画绘制。先给分支条件、箭头和节点留够空间，再移动整图。把图缩进小格会连同标签字号一起改变。已有位图的标签保存在像素中，需要改字形时可从已知题意重建节点和连线。

```tex
\begin{circuitikz}[flowchart]
\draw (0,0) node[rectangle]{B1};
\draw (0,-2) node[diamond]{B2};
\draw[->] (0,0) -- (0,-2) node[midway,right]{i≤10};
\end{circuitikz}
```

照片上的流程图、图标及插图应和正文落在同一纸面上。整页或局部 `view="review"` 的 `diagram_perspective_check` 给出图框当前四角、同位置沿纸面两轴的参考四角、四边的方向差以及底边/顶边宽度比。用 `preview_arguments` 比较原纸与成稿，必要时用 `native_image_arguments` 放大看节点、箭头和标签。沿图上下边比对原纸横线，再沿左右侧比对页边、表格竖线或连续横线的端点。纸面模型可能只校准了旋转；没有足够参照时保留不确定性。根据模型得到的四角不构成四个独立实测点。

整体已协调时保留原图。图和字都偏时先核对纸张标定；仅图形偏斜、且原纸有清楚的四角参照时，用当前版 `layout_arguments` 找根 ID，调用 `adjust_glyphs(whole_drawing=true, ids=[根ID], target_quad=四角)`。四角按左上、右上、右下、左下填写。只移动整图用 `place_center`。独立位图标签随根图共同变换；原先手动挪过的标签可用 `separate_detail_alignment` 核对。四角操作从原始图块布局重建，单纯平移保留局部几何编辑。修后复看相同区域和附近正文。`view="layout", drawings_only=true` 列出整图；`illustrations_only=true` 仍可选取位图的独立细节。

照片建稿和预览返回的 `paper_focus_check` 可用于比较不同位置印刷边缘的过渡宽度。请在推荐的原尺寸局部内对照底纸和成品，看同一位置的印字、细横线、手写字和图线。清晰度渐变时连同中间过渡区一起看。确有不协调时只选受影响的字或图块轻调柔化，复查改动区和原先清晰的区域。空白或低反差区域可能缺少测量依据。

判断照片上的字是否过重时，在整页复核的 `local_paper_ink_check` 中先找第一行，再比较中、下部的样本。按 `preview_arguments` 打开原尺寸的底纸和成稿，留意相邻的印字和细线。纸面亮度、印字浓淡和笔画清晰度是三种不同的线索。若标题比同处印字明显更深，可用 `layout_arguments` 定位字形，逐行调整 `adjust_glyphs.opacity`，以 `compare_revision` 查看交界与原先合适的区域。单个图块跨过深浅边界时，`opacity_ramp=[[0,65],[60,100]]` 会从图块顶部的 65% 逐渐过渡到高度 60% 处的 100%，下段维持原浓度。这些百分比乘在该字形原有的 opacity 上。

用户希望输出更接近轻微虚焦的照片时，先用 `preview_handwriting(view="image", export_blur_px=0.6, region=…)` 与同区域的 `0` 档比较。客户端可能缩放整页，局部裁图保留原始像素。选定后对同一稿件版本调用 `export_handwriting(format="zip", export_blur_px=0.6)`。数值为高斯模糊的标准差，范围 0–2 个输出像素。默认值为 0。纸与墨在合成后一起柔化，透明页保留透明度。PDF 和稿件自身的设置独立于这项 PNG 交付选项。

普通导出省略柔化参数。仅要求「稍微柔一点」时，可从均匀的 `export_blur_px=0.6` 试起。若指定上软下清、右上角偏软等方向，改用 `export_blur_gradient`，在同一版的预览和 ZIP 导出中传相同的对象。例如：

```json
{
  "from": { "x": 0.5, "y": 0.12, "sigma_px": 0.8 },
  "to":   { "x": 0.5, "y": 0.60, "sigma_px": 0.0 }
}
```

两个点的 `x/y` 以最终整张图片为参照，左上角为 (0,0)，右下角为 (1,1)。`sigma_px` 的单位是原图像素。强度按沿两点连线的像素距离比例平滑改变，两端以外维持端点值。上例在纸面上部使用 0.8 px，自高度 12% 起逐渐变清晰，60% 以下保留原像素。把两点放在一条斜线上即可指定斜向渐变。更换或旋转底图时，按新整页重新选点。两种柔化参数只能选一种。用 `view="image"` 和 `region` 分别查看两个端点及中间区域；局部复用整页的坐标和效果。

照片 PNG 的整页或局部复查可能返回 `png_finish_comparison`。在同版的两个参考区分别用 `clear` 和 `gradient` 原样调用 `preview_handwriting`，核对偏软一侧的纸与笔迹是否更协调，以及清晰一侧的小字是否完整。两端取自同方向可比的纸面印迹；较宽的印刷边缘也可能来自纸张或印刷。需要时可把两档裁区同步移到附近字迹。两档差别很小或细字变淡时，可直接交付清晰版。

作业表可用正文横线设置参考线，将同一页的课程、姓名等字块分别定位。若侧栏印字自下往上读，将原字块的左上、右上、右下、左下四角依次投到侧栏的左下、左上、右上、右下。复查时按栏核对读向、印字和留给老师的评分区。`changed_pixels_outside_reference` 也会计入正文参考区外有意填写的表头和侧栏，应结合这些栏位解读。

客户端已知目标值时，可在 `tune_handwriting` 中同时传 `changes={"perturb_theta_sigma":0.07}` 和 `readback_variation=["perturb_theta_sigma"]`。成功回执的 `effective_changes` 给出写入前后的有效值，用于直接核对本次写入，省去事后再读一次。最多点名本次提交的两个 `variation` 控件。提交 `null` 时读回继承值，有效值相同的键会省略。若要根据旧值决定改多少，仍应先用 `describe_controls` 读取该稿当前版本的值。

同页复盘在有可比样本时给出 `adjacent_row_check` 和 `illustration_ink_check`。复用其 `preview_arguments`，或逐项调用 `separate_preview_arguments`，在原图尺度看邻行字宽和图线附近的正文。`evidence.adjacent_rows` 分别记录两行的横纵伸缩比和照片投影前的垂直缩放，能区分字被拉宽和整行等比放大，`evidence.illustration_contrast` 记录采样区相对底纸的亮度下降及像素数。同一回执的 `ink_footprint_width_px` 用新增墨迹的面积与周长估算有效宽度，单位为原图像素。标签结构和节点交点都会影响数值，仍需看同倍率裁图中的具体字干、框线和箭杆。

如果字像贴在照片上，先分清是墨迹边缘过锐，还是纸面光照、阴影或墨色对比造成的观感。例如，纸面右侧有阴影，但用户认为笔画已经合适，就保留原样。如果用户明确指出笔画边缘过锐，或原尺寸成品裁图中的笔画边缘确实比附近可比的实拍印字或横线更锐，可以小幅柔化试一版。比如用户说“只改第一行，第二行保留”，用 `preview_handwriting(view=layout)` 找到第一行对应的字，再用 `adjust_glyphs` 的 `softness` 只调这些字。只有用户要调整整份稿子时，才用 `tune_handwriting` 的 `ink_softness`。用户要求保留墨迹时，直接沿用原版。

需要核对时，照片整页复盘的 `photo_appearance.preview_arguments` 可直接交给 `preview_handwriting`。有页内文字基线样本时，会返回字迹附近的原尺寸底纸和成品裁图，也可以自己圈选。试调后在新版本沿用原选区，用 `compare_revision` 指向旧版本，对照底纸、改前和改后三张实际裁图：底纸用来看原有阴影和印记，两张成品用来看细笔是否糊掉、对比度是否下降。如果用户点名第二行要保留，也对照第二行的改前和改后。效果变差或拿不准就保留原版。只有文字回执时，把用户观察到的情况说清楚，例如“你觉得边缘已经合适”；还需要目视判断时，请用户看裁图。字号与可写空间是否相称可另查 `layout` 或 `typography` 组。正文的柔化和粗细以投影前纸面像素为单位，透明度用百分比；只改墨迹组参数会保留已有的单字移位和透视调整。更换字体、字号或参考线后，应在新版本重新检查选区。

需要保留手动移字时，在 `tune_handwriting` 顶层传入 `preserve_local_adjustments=true`。例如，稿件中仍有字形调整时，更改 `variation.perturb_theta_sigma` 会返回一个受影响的节号，稿件停留在原版本。只更改墨迹或相机元数据仍可保存。被拒绝后应保持 `true`。只有用户明确同意新布局不再应用这些手动调整时，才可传 `false`；旧版仍可回看。

例如，先前已确认行距 56、左边距 67，后来要求恢复导入时的参考线并保留这两个数值。在同一次调用中传 `paper_guides=[]` 和 `changes={"line_spacing":56,"left_margin":67}`；想让文字重新跟随底纸时，省略相应数值。如果之前摆好的字也必须留在原位，再传 `preserve_local_adjustments=true`。补回行距和边距仍会触发重排；若保护生效，整次请求停在原版本。

`tune_handwriting(font_path=…)` 会把本机 TTF/OTF 随稿保存。可用返回的字体标识在同一稿内切回该字体。墨迹组的 `transparent_background` 控制原尺寸 PNG 预览和 ZIP，PDF 保留纸张。透明稿复盘会把墨迹放回底纸，方便判断实际可读性。

### 比较两版，找回当时的依据

先对要看的两个版本分别调用 `preview_handwriting(view="review", revision=…)`，记下返回的 `review_id`。用户明确表达偏好后，用 `annotate_review(draft_id, review_id, origin="user_quote", text=…)` 保存原话。模型自己的观察使用 `model_observation`。

续稿时，`read_section(draft_id=…, view="trajectory", section=2, feedback_origin="user_quote")` 只返回归在第 2 节的用户原话，每条带有关联版本和 `review_id`。结果按关联稿件版本从高到低排列；事后补在旧版上的评语仍归旧版。省略 `section` 可查全稿，省略 `feedback_origin` 可查所有来源。按节筛选时只含明确归在该节的事件，全稿调参记录需在全稿轨迹中查看。每页默认 12 条、最多 50 条匹配事件，有下一页时，用 `read_section(draft_id=…, view="trajectory", cursor=next_cursor)` 续读。游标沿用首页的版本、筛选条件和当时已有的复盘、评语；遍历期间新增的记录可在新查询中查看。旧客户端仍可按 `next_offset` 跳页，并发补评时偏移可能变化。

例如，比较第 1 节第 1 页的 v3 与 v4：

```json
{"draft_id":"…","view":"review","section":1,"page":1,"revision":4,"compare_revision":3}
```

该调用读取两版各自最近归档的该页复盘，返回测量、所引用的评语及其间全稿的编辑动作。差值为 v4 减 v3。先确认正文仍然可见，再结合每个区域的支持样本数解释偏差。全局墨色设置相同只说明参数一致，局部精修及肉眼观感还要另查。可用 `offset/limit` 翻阅编辑动作。某版缺复盘时，先查看所缺版本；算法不同、页面内容改变或尺寸不同时仅列两侧证据，保留比较限制。

如果同一版本、同一页有多张检查单，且要以用户看过或点评过的那张为准，在上述调用中加上 `"before_review_id":"原检查单号"`。原单必须属于同一稿件、`compare_revision`、节和页；不匹配会报错，不会改用别的单。新版仍取该位置最近归档的检查单。

精确复查用 `read_section(view="review",draft_id=…,review_id=…)`，跨会话可用。`before_review_id` 只选择保存的测量和评语，不还原图片，也不能和 `region` 一起用。按版本取 `view="image"` 或局部裁图时，输出按当时的运行环境生成，不能仅凭版本号认定与原单像素相同。像素摘要用于核对重渲染结果，系统不为每次复盘归档整页图片。

使用 Windows 上的 Python 客户端脚本时，若只有终端显示的中文乱码，可以将该客户端的标准输出和终端设为 UTF-8（例如向 Python 进程传入 `PYTHONIOENCODING=utf-8`）。

### 原照中的墨色与焦点

原纸按 `paper_mode=photo` 导入后，已追踪的纸线或用户指定的参考线会建立纸面到照片的坐标映射。在具备这项映射的稿件上，`describe_controls(group=ink)` 提供两个仅处理新增墨迹的选项。文字、公式、表格、流程图和已描线的位图轮廓共用这层墨。两项设置可单独放入 `tune_handwriting` 的 `changes`，可传 `null` 恢复原值。调整后按同一页、同一选区复查；保留足够清楚的笔迹。

- `photo_ink_light` 取 0–100。数值越大，非零墨色通道越多地随脚下的纸色相乘。纯黑墨的色值仍为零。用邻近的实际纸纹、印迹和新增笔迹比较冷暖与反差，单凭该区变暗无法判定曝光。若边缘过硬，可分别试局部透明度或焦点。
- `photo_ink_focus` 的 `from`、`to` 各给 `x`、`y`（整张原照的 0–1 坐标）和 `sigma_px`（0–2 个原照像素）。沿两点之间逐渐变焦，外侧维持对应端点的值。用原尺寸裁图判定远近清晰度，清晰端可保留 0。柔化发生在透视投影之后，纸面照片保持原样，PDF 与可见 PNG 共用同一处理。

## 普通作业的经验检索与总结

普通作业可直接用题目原话查询，例如 `search_homework_experience({"query":"保留旧教材的分数命令，计算行要排成上下分数"})`。SQLite FTS5 对每条经验的适用条件、动作、理由按 BM25 排序，三栏权重依次是 4、2、1。连续汉字按相邻双字切分，拉丁字母和数字按词处理。不同词元可以分别命中。题面中明确排除的内容也可能在字面上匹配，采用前须读返回的 `scope`。全文查询接受最多 1200 个字符，每页最多 20 条，可用 `next_offset` 翻页。

原有 `search_homework_experience({"tags":["homework","table","formula"]})` 仍按标签检索；规则的所有必要标签都要被查询覆盖。也可以同时传 `query` 和非空 `tags`，先限定标签范围，再按全文相关性排序。作业以 `style.homework=true` 保存后，`experience_search` 会提示宿主使用原话及可选标签。两种检索都只展示已验证且有效的经验，返回来源检查单。未命中时可查看 `available_tags`。

修订已有作业时，先用 `preview_handwriting(view="review", revision=修前版, section=节, page=页)` 查看原版受影响的位置，保存 `review_id`。改后核对同处，必要时带 `compare_revision` 和同一 `region` 对照。若交付时才补看旧版，在结论里注明事后复核。提交候选时尽量沿用建稿主题词，只选检索该做法所必需的标签，把具体条件写进 `scope`。

普通作业导出后，`experience_reflection` 附上 `export_id` 和最多八个已检查页面的引用。如果同一页在之前的版本也有原生检查单，`earlier_reference` 会指向最近的已检查旧版。更多页面可通过 `read_section(view="review")` 查回。

- **一条经验写一个可单独验证的动作。** 宿主填写适用标签 `tags`、具体条件 `scope`、动作 `action`、结合页面观察写出的理由 `reason`、该条自己的检查单 `reviews`。同一道题若有两个独立问题，可拆成两条，分别验证、检索和退役。拆分粒度由宿主判断。每次调用可传 0–16 条。同标签、条件和动作的重复提案复用原 ID。
- **有修前、修后检查单时，在最终答复前提交复盘决定。** 调用 `record_homework_experience`，逐条引用本次导出和交付版检查单，可附同稿旧版。只有本题的数值或笔误可传 `rules=[]`。干净完成的作业也可以直接交付。工具返回每条的 ID 和状态；宿主可以向用户简述刚记录的做法及其待验证状态。
- **下次用新作业的原话或主题直接搜条目。** 持有 ID 时可用 `read_homework_experience` 审计来源及逐次验证。不同会话共享同一个 Panache 数据目录时可见同一经验库。
- **验证由发起验证的宿主负责。** `validate_homework_experience` 需要独立正例和边界例，各有自己的交付与检查单；宿主判断实际收益和是否误伤。双方都通过才生效，任一失败或主动 `retire_homework_experience` 会从普通检索撤下。存储层核验证据身份，无法判定推理是否正确。保留原检查记录的连接可检索经验，其导出只报告交付情况。

## 多轮手写实验

用户要求比较稿件、试验改法或改进下一轮策略时，宿主模型负责读图、提出假设、判断并说明理由。Panache 使用现有工具生成和审阅稿件，在本机的稿件数据库中保存任务。其他提供方也可按同一 MCP 契约提交决策。

1. 用 `save_section` 准备初稿。`read_rsi_policy({})` 列出策略版本，初始版本为 `pilot-v1`。用 `start_rsi_task` 提交稿号、起始版本、目标、策略 ID 和实际的 `decision_provider`。任务固定使用当时的规则。
2. 用 `advance_rsi_task` 传当前 `expected_step`（初始为 0）。`request_evidence` 写明要消除的疑问。用 `preview_handwriting` 传同一 `rsi_task_id` 和明确的稿件版本，查看图像、布局或局部裁剪并取得 `evidence_id`。整页检查也可直接引用同稿同版已有的 `review_id`，其首次入档时间见 `filed_at_revision`。任务预览单据只在本任务有效，每个任务最多 64 份。设置 `PANACHE_MCP_PRESERVE_REVIEWS=1` 的连接可以查旧单、引用旧单，或省略 `rsi_task_id` 临时看图。
3. `revise` 引用同版的 `review_ids`、理由、预期变化和一个编辑工具。调用该工具时在 `rsi_decision_id` 传回 `decisions` 末项的 `decision_id`，并使用该稿的当前版本。该工具写入新版本时，同一笔事务会把新版登记为候选。如果回执显示设置已相同且版本号未变，可以沿用当前候选继续审阅。
4. 从 `candidate_revisions` 中选择满足目标的一版，以 `select` 提交其检查证据和取舍，再以 `selected_revision` 调用 `export_handwriting`。目标无法满足时用 `stop` 记录未解问题。最后一个决策名额留给选择或停止。重连后用 `read_rsi_task` 和保存的任务 ID 读取决策、预览参数与摘要，或用 `read_section(view=review)` 查整页单据。局部裁剪可按原参数重绘；将返回图片的 Base64 字符串做 SHA-256，即可与当时的图片摘要核对。
5. 用 `publish_rsi_policy` 引用父策略和已结束、有证据的源任务，写明下一版的执行、审阅、成稿选择、实验选择规则和预算。后续任务显式选用新版本。用 `validate_rsi_policy` 记录新版本在独立稿件上的实测结论、失败和局限；用 `read_rsi_policy` 查回这些宿主评估及对应任务。

需要验收指引时，调用 `read_rsi_policy({"policy_id":"pilot-v1","include_evidence_guide":true})`，并记录响应的 `evidence_guide.version`。回放时传入 `evidence_guide_version` 可读取同一版。按任务选择 `checks` 中的项目，例如按 `formula_rendering` 从原尺寸成稿读回分式，按 `mixed_content_projection` 对照图表两端与附近纸纹，按 `focus_and_contrast` 检查不同区域的纸色和笔迹。将调用参数补上实际稿号、候选版本和节页，裁区按 `region_from` 取得。[实拍作业指引](evidence-guide-v2.json) · [首版指引](evidence-guide-v1.json)

## 验证

构建后可用官方 Python MCP 客户端跑一次 stdio 端到端测试。`--out` 可选，用于保留诗稿的预览和 PDF。

```sh
uv run --script crates/panache-mcp/tests/smoke.py target/release/panache-mcp --out output/pdf
```

局部复查盲评使用合成页面。构建后运行以下命令，在新的输出目录中生成两组顺序配平的图片与任务，以及单独保存的答案和逐例统计。给评审者各发一组，待其回答后再打开 `private/key.json`。脚本另外核对源图像素。调用数和字节数只统计取复盘结果的开销，选区已提供。

```sh
uv run --script crates/panache-mcp/tests/local_review_experiment.py target/release/panache-mcp --out output/local-review-pilot
```

内置字体同名替换后，检查单编号仍能锁定原测量记录。可用独立的 stdio 测试复现：

```sh
uv run --script crates/panache-mcp/tests/review_pin.py target/release/panache-mcp app/web/prepare-text-worker.js
```
