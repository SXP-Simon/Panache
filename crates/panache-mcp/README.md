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

稿件会原样保存嵌入的图片，正文里的插图会画成手绘线稿，无法保留原彩。颜色很重要时，请先看这一页的小样，别把插图改成整页底纸。

可以先说「用这段话给我看第一页」，看过后说「字大一点」，再说「就用这一版」。客户端按同一稿件的版本号取预览和导出。查看小样使用 `preview_handwriting(view="image")`，无需创建检查单。

想在聊天里拿到文件时，能处理 MCP 内嵌文件的客户端可在导出时传 `include_file=true`，把收到的 PDF 或 ZIP 作为附件显示给用户。512 KiB 以内的完整文件可以随回复传送。更大的文件仍在运行 Panache 的电脑上；两端共用磁盘时可直接打开返回的路径。只有客户端已经提供可打开的附件或链接时，才告诉用户「附件在这里」。

客户端从内嵌资源取出文件后，应由客户端生成自己的下载入口，不依赖模型在回复里拼链接。资源里的 `panache-export:///…` 仅用于标识，不是下载地址。把交付状态和已经可用的下载入口交给模型即可，不要把文件的 Base64 内容放进模型上下文或普通日志。

使用自己的纸张时，在第一次调用 `save_section` 时传入 `paper_path`，例如 `{"markdown":"第一题","paper_path":"C:/作业/南昌大学横线纸.jpg"}`。路径指向运行 MCP 的电脑上的图片。默认保留原照片，按识别到的横线投影字迹和插图。`paper` 返回排版尺寸、边距、行距、识线结果，投影时另有原照尺寸。可用 `preview_handwriting(view="paper")` 单独看底纸，或在导入时通过 `paper_guides` 指定参考线。需要校平底纸时传 `paper_mode="flatten"`。无可靠横线时保留底图，使用普通行距。纸张随稿件保存一次，后续追加、回查、预览和导出可在原图移动后继续使用。

如果照片是聊天附件，先用客户端支持的文件传送功能，把照片交给 Panache。云端没有这项功能时，可在照片所在电脑连接桌面版再使用。复制手机或另一台电脑上的路径不能传照片。带视觉能力的模型可以查看客户端转交的预览图。客户端或模型只能处理文字时，可读取版面和像素测量，并请用户打开导出文件确认外观，再按反馈修改。

| 工具 | 用法 |
| --- | --- |
| `list_fonts` | 按名称、文件名或来源（`bundled`、`user`、`system`）检索字体。默认 20 项，使用 `next_offset` 翻页。为作业、实验报告选笔迹时，指导模型展示中英数混排小样，按用户偏好定稿。 |
| `save_section` | 用 `markdown` 新建稿件。首次可传标题、字体、字号、纸样、墨色、种子和作业排版模式。返回 `draft_id`、版本号和节号。 |
| `list_drafts` | 找回本地稿件和最新版本。每批 20 条，可传 `offset`。 |
| `read_section` | `summary` 取版本、长度和样式；默认 `excerpt` 隐去正文中已识别的内嵌图片数据；`source` 读取精确 Markdown。后两种视图按字符分页，默认 1000 字，单次最多 4000 字。 |
| `preview_handwriting` | 默认返回首页 PNG。用 `section`、`page` 查看指定节中的一页，两者从 1 开始。 |
| `export_handwriting` | 按节顺序导出整份稿件，返回绝对路径、版本和实际页数。格式可选 `pdf` 或 `zip`，ZIP 从 `0.png` 开始编号。导出结果的 `review.unreviewed_pages` 按打印顺序列出缺少整页复盘的 `section`、`page`。将这些坐标与导出的版本号传给 `preview_handwriting(view="review")` 可逐张补看。 |
| `describe_controls` | 调参时可将参数直接放在 `changes` 内，也可写成 `{"changes":{"variation":{"perturb_theta_sigma":0.07}}}`。先列参数组，再按 `group` 查看单位、范围和枚举值。附上 `draft_id` 和 `revision` 可读取该版的实际值。 |
| `tune_handwriting` | 可在原稿上更新参考线、导入本机字体，并一次提交多项全稿参数，如 `{"ink_opacity":85,"word_spacing":2}`。`null` 恢复建稿时的设置。 |
| `storage_usage` | 查询目录和逐稿用量，以及当前预算。 |
| `plan_cleanup` | 按稿列出废弃临时文件和受保护的已交付导出。 |
| `apply_cleanup` | 复核计划，仅清理选中的废弃临时文件。 |
| `annotate_review` | 将用户原话或模型观察挂到指定复盘 ID，保持稿件版本号。 |
| `adjust_glyphs` | 先用 `preview_handwriting(view="layout")` 取编号和坐标，再按同一节、页和版本调整选中字形。 |

若本次只改稿、打印和统计缺单页，可在客户端的 MCP 服务配置中设置 `PANACHE_MCP_PRESERVE_REVIEWS=1`。该连接仍可正常调参、看图和导出，完整检查单与评语会保留原样。

例如用 `list_fonts(query="楷", source="system", limit=8)` 检索系统字体。把 `entries[].id` 用于建稿的 `style.font` 或调稿的 `changes.font`。随包字体继续接受原文件名。个人和系统字体会随稿保存，删除源文件后仍可预览历史版本。TTF、OTF 和 TTC/OTC 中带轮廓、单个字面大小不超过 32 MiB 的字体可供选择。

桌面与 MCP 共享“我的字体”目录，`list_fonts` 的 `user_dir` 给出绝对路径。Windows 使用 `%LOCALAPPDATA%/Panache/fonts`，macOS 使用 `~/Library/Application Support/Panache/fonts`，Linux 使用 `$XDG_DATA_HOME/Panache/fonts`（默认 `~/.local/share/Panache/fonts`）。可通过 `PANACHE_USER_FONT_DIR` 指定绝对路径。把字体放入后调用 `list_fonts(source="user", refresh=true)`。

面向 AI 客户端的调用示例、披露边界和测量口径见[工具设计](tool-design.md)。

查归属某版、某节、某一页的整页复盘，可用 `read_section(view="review", revision=3, section=2, page=1, draft_id=…)`。返回最近记录在这个位置的测量值、原检查单编号及注明来源的评语。该位置没有记录时返回 `status="no_recorded_review"`；直接按数字页码查单不会排版，也不判断该页是否实际存在。已知检查单编号时仍可按 `review_id` 精确读取。

如果用户问“增加某段话以前，某一节最后那张验过吗”，把新增段落中独有的原文字串传给 `before_text`，目标节传 `section`，页码传 `page="last"`。服务端在该字串首次出现的前一版排出目标节的实际末页，只读取该位置的检查单。返回的 `before_text_match` 标明新增文字所在节和引入版本，顶层的 `revision`、`section`、`page` 标明查单位置。字串跨节重复或同节删后重加时，结果列出最早两个加入时点及对应的前一版。可查的正文节附有简短开头，便于区分补记所在节和实际要查的节。请用户选择，也可分版回答。按补记或末页查多节稿时需明确待查节号。无匹配或首次建稿就存在时，请核对原文或提供明确版本。末页定位会按该版字体和版式分页，不返回图片，也不会新增检查单。单据的 `revision` 表示受检版本，`filed_at_revision` 表示首次入档时稿件的最新版本。旧库没有保存这一信息的单据返回 `null`。回答“补记前验过吗”时请同时转述 `receipt_summary` 中的时间结论。

预览的页码在每一节内从 1 开始。翻过一节末页时，错误信息给出这节的实际页数，以及所查版本中下一节的起始页；历史版本已到末节时会提示到此为止。

长作业可以按题组或章节分次传入，每节从新页开始。需要连续排版的段落放在同一节，公式、表格、代码块也应完整放在一节内。追加时带上 `draft_id` 和上次返回的 `expected_revision`；修改已有节时再给出 `section`。另一位客户端抢先保存后，用 `read_section` 复核最新内容再提交。

每次保存只转换这一节，Markdown 原文和整理结果存入本地 SQLite。预览某节第 N 页时，引擎从该节开头排到第 N 页，只编码选中的一页。进程内保留最近生成的四张预览，修改其他节仍可复用。预览和导出传相同的 `revision` 可锁定稿件。种子和样式随稿保存，复现时需使用相同字体和引擎。

整稿上限为整理后 10 万字、200 页。完整导出只在调用导出工具时执行；客户端可以取消，提供进度令牌时可看到已完成页数。ZIP 逐页写盘，PDF 在内存中组装压缩页面后写盘。结果成功后才移入 `exports/`。稿件及历史持续保存在 `PANACHE_MCP_HOME`；Windows 默认是 `%LOCALAPPDATA%/Panache/mcp`，其他系统默认是 `$XDG_DATA_HOME/Panache/mcp` 或 `~/.local/share/Panache/mcp`。

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

1. 表格、无横线纸和画作均可排字。用户已指定位置或委托选位时，直接按意图排版。落字区有歧义时，简短问“要写在哪个栏，哪些地方留白？”若必填区域在画外，或失焦、遮挡、透视已使它无法定位，建稿前指出具体缺哪一块，请用户补拍该区域或确认只填可见部分。已明确要求只写正文时，直接填写可定位的正文区。
2. 用 `save_section` 导入照片并保留版本号。用 `preview_handwriting(view="review")` 取得同一页的底纸、成品和叠图。整页复查图长边最多 900 像素，像素坐标以返回的 `photo_size` 为准。检查有字区域的横线、页眉、页边和需要保留的图案。
3. 调用 `tune_handwriting(draft_id, expected_revision, paper_guides, note)` 在原照片上重排全文。至少给两条参考线，每条提供行号与左右端点。无横线纸也可以指定想写入的区域。传空数组恢复建稿时的校准。旧版本仍可回看；改写书写区域会重置冲突的边距覆盖，重新排版后需重新选字。
4. 局部改动用 `preview_handwriting(view="layout", region=[[x,y],…])` 圈选字形中心，结果按页分批。把选中的 ID 和相同版本交给 `adjust_glyphs`。`place_center` 将一组字移到指定照片位置；`target_quad` 按左上、右上、右下、左下四角放置所选字块，替换该组已有几何调整。局部字形还可分别调倾斜、浓度和笔画。调整后复查新版本。
5. 用 `read_section(view="trajectory")` 回看该稿的近期操作、简短调整理由和按页记录的复盘指标。有下一页时，把 `next_cursor` 作为下一次调用的 `cursor`。把需要人判断的歧义带回当前会话；确定符合用途后导出同一版本。

要核对局部改动，用 `preview_handwriting(view="review", region=…, revision=新版本, compare_revision=旧版本)` 查看同一区域的底纸、改前和改后图。移动字块时还可用 `previous_region` 圈出旧位置。需要保护的文字或页眉可单独圈选复查。区域使用原尺寸成品像素。[局部坐标与测量示例](tool-design.md#局部改动的复查)

作业表可用正文横线设置参考线，将同一页的课程、姓名等字块分别定位。若侧栏印字自下往上读，将原字块的左上、右上、右下、左下四角依次投到侧栏的左下、左上、右上、右下。复查时按栏核对读向、印字和留给老师的评分区。`changed_pixels_outside_reference` 也会计入正文参考区外有意填写的表头和侧栏，应结合这些栏位解读。

如果字像贴在照片上，在照片整页复查的 `photo_appearance` 中取 `preview_arguments` 再调用一次 `preview_handwriting`。有页内文字基线样本时，这组参数会给出该版本一处字迹附近的原像素底纸和成品裁图；也可以自己圈选。对照邻近印字或横线的边缘清晰度、墨色深浅，再看字号与可写空间是否相称。用 `describe_controls` 指定稿件、版本和 `ink`、`layout` 或 `typography` 参数组可查当前值。正文的柔化和粗细以投影前纸面像素为单位，透明度用百分比。仅修改墨迹组参数时会保留已完成的单字移位和透视调整；更换字体、字号或参考线后应在新版本重新检查选区。改一版后，对同一选区加入 `compare_revision` 比较。只有文字结果的客户端可转述测量，请用户看图判断观感。

客户端已知目标值时，可在 `tune_handwriting` 中同时传 `changes={"perturb_theta_sigma":0.07}` 和 `readback_variation=["perturb_theta_sigma"]`。成功回执的 `effective_changes` 给出写入前后的有效值，可省去写前、写后各一次查询。最多点名本次提交的两个 `variation` 控件。提交 `null` 时读回继承值，有效值相同的键会省略。若要根据旧值决定改多少，仍应先用 `describe_controls` 读取该稿当前版本的值。

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

精确复查用 `read_section(view="review",draft_id=…,review_id=…)`，跨会话可用。要看图时再按版本取 `view="image"`。像素摘要用于核对重渲染结果，系统不为每次复盘归档整页图片。

使用 Windows 上的 Python 客户端脚本时，若只有终端显示的中文乱码，可以将该客户端的标准输出和终端设为 UTF-8（例如向 Python 进程传入 `PYTHONIOENCODING=utf-8`）。

## 验证

构建后可用官方 Python MCP 客户端跑一次 stdio 端到端测试。`--out` 可选，用于保留诗稿的预览和 PDF。

```sh
uv run --script crates/panache-mcp/tests/smoke.py target/release/panache-mcp --out output/pdf
```

局部复查盲评使用合成页面。构建后运行以下命令，在新的输出目录中生成两组顺序配平的图片与任务，以及单独保存的答案和逐例统计。给评审者各发一组，待其回答后再打开 `private/key.json`。脚本另外核对源图像素。调用数和字节数只统计取复盘结果的开销，选区已提供。

```sh
uv run --script crates/panache-mcp/tests/local_review_experiment.py target/release/panache-mcp --out output/local-review-pilot
```
