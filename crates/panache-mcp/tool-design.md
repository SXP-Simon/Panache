# 用 Panache MCP 排版和检查手稿

假设用户发来一张斜拍的实验报告纸，希望把记录写在横线上，英文和数字也像同一个人写的。第一次接入 Panache 的客户端需要完成三件事：找到能写的位置，选好笔迹，确认导出的那一版确实符合要求。这份指南按这个顺序介绍该用哪个工具、该看返回结果中的什么内容。

## 从一行字开始

在 AI 客户端登记 Panache 的 stdio 配置后，调用 `list_fonts`。能列出本机字体，就可以试写第一行。用 `save_section` 传入 Markdown，记下返回的 `draft_id` 和 `revision`，再用这两个值调用 `preview_handwriting`。**省略预览的 `view` 时，返回这版手稿的单页 PNG。** 指定节和页时从 1 开始计数。

作业或实验报告适合直接拿一句正文试字，比如“样品 A 的质量为 12.5 g”。新稿只选主字体，英文和数字默认跟随它。用户已经选定字体，想要“稍微草一点”时，保留主字体和种子，用 `describe_controls(group="variation", draft_id=…)` 查看当前值。例如将 `perturb_theta_sigma` 从 0.05 调到 0.07 弧度，比较同一行改前改后的倾斜、数字和单位。也可少量调整 `perturb_x_sigma` 和 `perturb_y_sigma` 改变字的位置。在目标纸张和字号下看看：中文和英文的笔画粗细是否协调？`12.5` 和单位能否一眼辨认？风格未定时，把小样给用户看，说清推荐理由，再问“这种笔迹可以用在整份报告里吗？”用户已经定好或委托选字时，就继续排版。

用户明确要“偶尔像写错了又划掉”时，用 `describe_controls(group="strike", draft_id=…)`，在非等宽排版中可试 `strikethrough_probability=0.005`。引擎随机插入一个带划痕的额外字符，后面仍写正确内容。短页可能一次也没有。只调整这个概率后，对照同一行的两版预览，看到划痕才报告出现过涂改，同时检查换行和读数。要划掉指定词时应说明当前能力只提供随机位置，Markdown 的 `~~词~~` 在准备正文时会变成普通文字。

只有用户对英文或数字单独提出要求，才需要查 `describe_controls(group="typography", draft_id=…)`。编辑旧稿时，省略参数会保留原设置。要撤销以前的西文字体和缩放，可以给 `tune_handwriting` 传这组 `changes`：

```json
{"latin_font": null, "latin_digits": false, "latin_font_scale": 100}
```

主字体缺字时，引擎可能使用备用字体，最后以实际成图为准。客户端决定是否将工具图片传给模型。如果用户能看图、模型只收到文字，模型可以报告坐标和测量结果，再请用户确认笔迹的观感。

## 一次改稿需要哪些调用？

以“把整稿墨色调淡，再把第二页的‘还’沿横线往右挪一点”为例。下表假设当前稿件为 v5，目标在第 1 节第 2 页。实际调用应使用服务端返回的版本号和字形 ID。

| 目的 | 调用与关键参数 | 看什么 |
| --- | --- | --- |
| 查这份稿的墨色 | `describe_controls(group="ink", draft_id=…, revision=5)` | 找到 `ink_opacity` 的当前值和范围。 |
| 调淡整稿 | `tune_handwriting(draft_id=…, expected_revision=5, changes={"ink_opacity":85})` | 保存后得到 v6。单改墨迹会保留已有的局部摆放。 |
| 找到“还” | `preview_handwriting(draft_id=…, revision=6, section=1, page=2, view="layout")` | 用文字、坐标和编号定位。这里假设查到 ID 37。 |
| 移动这个字 | `adjust_glyphs(draft_id=…, expected_revision=6, section=1, page=2, ids=[37], dx=4)` | 得到 v7。位移相对原始字框；以后只改 `dy`，会保留这次的 `dx`。 |
| 核对并导出 | 先在 v7 预览这一页，再用 `export_handwriting(draft_id=…, revision=7, format="pdf")` 导出 | 预览和导出指向同一版本。用户特别要求其他字保持原样时，再做下文的局部比较。 |

换字体、改字号或重设参考线，都可能让正文重新排版。这时应从新版重新找字。改写某一节后，该节原有的单字调整仍可在旧版本中查看；追加其他节时可以复用原节调整。如果需要更换本机字体，可用 `tune_handwriting(font_path=…)` 导入 TTF 或 OTF，字体会随稿保留。如果另一位客户端先保存了，先读最新摘要，确认目标仍在，再提交修改。局部图文较复杂时，可结合预览和字框定位公式、插图或经过排版转换的文字。

如果要交付只有笔迹的 PNG，可在墨迹组开启 `transparent_background`，再导出 ZIP；同稿导出 PDF 时会保留底纸。导出结果会说明当前版本哪些页已有整页复盘记录。

## 在照片上找到正确的位置

建稿时传入服务端能读取的 `paper_path`。默认的 `paper_mode="photo"` 在原照片上写字，保留拍照时的透视；`flatten` 使用校平后的底纸。先看返回的画布尺寸、边距、行距和横线识别结果，再决定是否需要手动校准。

- **有清楚的横线，但字没贴上去。** 在同一份稿上用 `tune_handwriting(paper_guides=…)` 指出第一条和最后一条可写基线，必要时补中间几行。每条包含行号 `row` 和原图上的两个端点 `left:[x,y]`、`right:[x,y]`，首行编号为 0。两个端点沿纸纹取，即使横线在照片里向上斜，也能给模型一个明确的书写方向。传空数组可恢复建稿时的校准。
- **没有横线，或者纸上有画。** `alignment="unverified"` 表示没找到可靠横线。用户已指定右下角或委托选位时，可以在该区域试排。左右都有空白、位置会影响画面时，再问用户想写在哪、哪里要留白。若任务要求填写表头，但表头被裁掉或遮住了，先请用户补拍，或确认只写可见部分。
- **只需调一块文字。** 在 `view="layout"` 中用原图像素圈选字形中心。投影稿的 `photo_quad` 给出原始字框的左上、右上、右下、左下四角，`photo_baseline` 给出原始基线两端，已有调整另列。要把一组字挪到图中的某点，用 `place_center`；让同一原始行的文字顺着照片上的横线或斜栏书写，用 `natural_line` 指定基线两端，跨行沿用同一缩放比例。需要精确映射到四角时才用 `target_quad`，结合回执中的轴向形变和相邻行判断效果。只需相对移动时用 `dx/dy`，它们的单位是投影前的纸面像素。纸面上水平移动，在照片上可能同时改变 x 和 y。

局部 `shape` 也在纸面投影之前生效。比如 `{"shear_degrees":4,"top_width_percent":94}` 会让字底向右倾，字顶略窄；设回 0 度和 100% 就还原。字号、行距和边距同样按纸面像素指定，可以在一次修改里一起调整。

**如果要改的是位图插图**，给布局预览加上 `illustrations_only=true`。同一个 `illustration_id` 下，`illustration` 是框线、箭头等主体，`illustration_detail` 是能单独选中的笔迹。要把某个标签写粗一点，可对它的 ID 用 `adjust_glyphs(thickness=0.5)`；还可调 `softness`、`opacity` 或 `color`。粗细与柔化以 0.1 px 为步长，归零恢复原效果，颜色用 `inherit` 恢复。每次最多选 32 个 ID。标签若与框线连成一片，工具只能把这片笔迹作为整体处理。

生成的 `circuitikz` 电路图不属于这个筛选范围。先看当前版本的页面图像，再在同一版本和页请求 `view="layout"`，用 `region` 圈住电路图的中心，不传 `illustrations_only`。布局中的电路图是一个整体 ID；移动整图可用这个 ID，改标签文字则编辑该节的 Markdown。

## 排好了，怎样验收？

先想清楚用户要确认什么。整页有没有字，只动了一个字，下一轮要接着哪一版改，这三种问题需要的证据不同。

| 想确认的事 | `preview_handwriting` 的参数 | 返回内容 |
| --- | --- | --- |
| 这页写在哪、是否看得见 | `view="review"` | 当前版的底纸、成品和参考线叠图，以及整页测量和 `review_id`。 |
| 这个字的墨色是否和照片协调 | `view="review", region=…` | 同一位置的底纸和当前成品两张裁图。照片整页复盘若给出 `photo_appearance.preview_arguments`，可以直接用它取得建议的局部。 |
| 两版在这块地方有何区别 | `view="review", region=…, compare_revision=…` | 底纸、改前、改后三张裁图。移动了内容时，用 `previous_region` 补上旧位置。 |
| 已经看过两版，只想读记录 | `view="review", compare_revision=…`，省略区域 | 读取两版已保存的测量、评语和期间的修改，只返回数据。用户只想查旧记录时，直接报告缺少哪一版的整页记录。用户另行要求新检查时，再对指定版本做整页复盘。 |

整页叠图中的橙线标出估计书写区，青线标出参考线。服务端在原尺寸像素上比较成品与底纸：任一可见 RGB 通道相差至少 8 级，就计为可见变化。它按页面上、中、下三区报告数量，也统计参考区外的变化。有正文却整页零变化，应检查墨迹透明度和落字位置。表头或侧栏可能本来就要写，看到区外计数时要回看用户指定的栏位。

要判断是否贴线，看有多少个字形基线采样点能在附近找到可信的底纸暗线，以及垂直偏差的中位数。没找到足够对比时会返回空值，纹理或校徽也可能被当作暗线。至于字迹像不像写在这张纸上，应放大笔画，对照旁边的印字、纸纹和焦点，再看粗细、边缘和字号。

### 局部改动的复查

例如要确认“还”移动后，旧处干净、新处有字、校名没动。下面比较第 1 节第 1 页的 v3 和 v4；两个区域应换成实际测得的坐标。

```json
{
  "draft_id": "…", "view": "review", "section": 1, "page": 1,
  "revision": 4, "compare_revision": 3,
  "region": [[160,210],[260,210],[260,250],[160,250]],
  "previous_region": [[40,210],[140,210],[140,250],[40,250]]
}
```

1. **先看两个位置。** `region` 圈新位置，`previous_region` 圈旧位置。多边形用原尺寸成品像素，原点在左上，向右、向下为正。每区用 3 至 32 个顶点，不自交，不用重复首点。裁图的 `crop_bounds` 是原图上的 `[x,y,width,height]`，返回图的尺寸见 `crop_image_size`，最长边最多 900 px。
2. **再查其他地方。** 对比两版的 `ink_pixels`，看旧区还剩多少墨迹、新区是否出现笔画。`difference.outside_union_changed_pixels` 统计整页中两区以外达到同一阈值的变化。图文重叠时会一起计数，可另圈校名单独查。阈值下计数为零仍允许细微色差；如果用户要求逐像素相同，应比较原尺寸导出图。
3. **解释意外变化。** `render_mode_change` 表示两版用了不同的笔迹渲染方式。普通文本首次精修时可能切换到逐字生成，连未选中的字也略有变化。投影照片从建稿时就使用逐字渲染。若保护区确有变化，应说明位置和程度；底纸、尺寸或页面内容变了，则分开检查两版。

### 下一轮怎样接着改？

`read_section(view="trajectory")` 按版本列出修改、简短理由和逐页复盘。比如用户说“留 v3 的墨色，用 v4 的位置”，可用 `annotate_review` 将原话挂到对应的 `review_id`，来源填 `user_quote`；模型自己看到“旧位置还有墨迹”，来源填 `model_observation`。下次可以按 ID 取回当时的记录，或按版本重新出图。局部复查即时渲染，要保存一条可引用的记录，需要做整页复盘。

<details>
<summary>实现客户端时，怎样解释两版测量的差值？</summary>

本机 SQLite 按稿件版本、节页、算法版本和成品像素摘要复用相同的观察。摘要使用 SHA-256，依次输入小端 u32 宽、高及原始 RGBA8 像素；透明预览在叠回纸张前计算。算法或像素改变后会产生新的复盘 ID，迁移旧记录时会保留测量并留空未知字段。轨迹存的是本稿的动作和结果，无须保存整段对话或每轮整页图片。

两版比较会取同一节页最近归档的观察，每版最多带回最近 50 条署名反馈，更早的可在轨迹中分页查找。页面成员摘要包含节版本和字形来源位置；重新保存正文后，即使页码相同，也可能无法量化比较。分区两侧各至少有 3 个暗线样本才报告偏差之差。参考区外的像素数以各版自己的书写区为准。如果同时改了字体、墨色和参考线，应结合成图判断原因，单项差值不足以解释观感变化。

保留每轮修改和外部反馈的做法参考了 [Reflexion](https://proceedings.neurips.cc/paper/2023/hash/1b44b878bb782e6954cd888628510e90-Abstract-Conference.html)、[SICA](https://github.com/MaximeRobeyns/self_improving_coding_agent) 和[外部反馈与自我纠错研究](https://proceedings.iclr.cc/paper_files/paper/2024/hash/8b4add8b0aa8749d80a34ca5d941c355-Abstract-Conference.html)。

</details>

## 怎样控制上下文和测量开销？

Panache 通过 `tools/list` 提供 13 个工具。模型可以直接建稿、预览、导出。需要调参时再用 `describe_controls` 查排版、字体、墨迹、扰动、删除线或拍摄信息中的一组。客户端决定把哪些工具说明、图片和历史消息交给模型；支持分页或延迟加载的客户端可以按需取用。[MCP 工具规范](https://modelcontextprotocol.io/specification/2026-07-28/server/tools) · [工具发现的设计背景](https://blog.modelcontextprotocol.io/posts/mcp-roadmap/) · [Claude Tool Search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)

- **找位置**用 `preview_handwriting(view="layout")`。默认一次取 12 个字形，最多 32 个，返回坐标和编号，不传图片。指定第 N 页时，引擎仍需从该节起点排到第 N 页。
- **接着写**先用 `list_drafts` 找回稿件，再用 `read_section(view="summary")` 读版本和长度。普通 `read_section` 默认返回摘录，用 `attachment` 替换识别到的内嵌图片数据。要改原文，分页读 `view="source"`，以该视图的偏移量续读，避免把摘录里的占位符写回正文。
- **交付文件**时，导出返回服务端的本地路径，客户端要能访问该文件。宿主负责执行权限和会话历史，应将稿件内容和工具结果中的用户文字作为数据处理。

### 用户说“只翻旧记录”时，客户端可以提供哪些工具？

对于只查询 Panache 稿件的请求，宿主可以在这一轮只提供 `list_drafts` 和 `read_section`。在给模型展示工具清单和向这台 Panache 服务转发调用时使用同一组名称。这样即使模型记得上一轮用过整页预览，也不会在查档过程中生成新的检查单。下面示例使用已连接到 Panache 的 Python MCP SDK 会话，`tools` 是客户端已发现的工具清单。

```python
history_names = frozenset({"list_drafts", "read_section"})

def history_tools(tools):
    return [tool for tool in tools if tool.name in history_names]

async def call_history_tool(session, name, arguments):
    if name not in history_names:
        raise ValueError("本轮只查询旧记录，可用 list_drafts 或 read_section。")
    return await session.call_tool(name, arguments)
```

宿主将 `history_tools(tools)` 交给模型，并把本轮的 Panache 调用全部交给 `call_history_tool`。拦下调用时，将异常文字返回模型供它继续查档。这个范围适用于用户明确要求翻旧记录的轮次。若同一请求还要打印旧稿，宿主可单独提供用户要求的导出操作，传入已核实的版本。用户要求改稿和打印、又要求保留检查记录原貌时，宿主可开放该轮需要的编辑和导出操作，并限制预览只转发 `view="image"`。导出结果已列出缺单页。标准 stdio 客户端也可单独启动一个设置了 `PANACHE_MCP_PRESERVE_REVIEWS=1` 的连接来处理这类轮次。它允许改稿、看成图、查原单和导出；写整页检查单或追加评语会在落库前返回可恢复的错误。这个设置作用于该服务进程，默认 0。

已知补记原文时，可以用 `read_section(view="review", before_text="…", section=正文节号, page="last")` 按当前运行环境重新分页，再查补记前正文末页对应的检查单。返回的页码和查单结论不能证明它是当时的末页；缺单时列出的其他页单号也不代表末页。知道原单号请按 `review_id` 查单，知道原页码则按数字 `page` 查单。若只知道大意，先从 `trajectory` 和 `source` 确认原文及待查的正文节。遇到重复加入时，按工具列出的修订分别核对，或请用户确认是哪一次。导出的 `review.unreviewed_pages` 使用节内页码，回查时带上同一次导出返回的 `revision`。查无存档时，无法据此判断用户是否在纸上看过。只有 `feedback[].origin="user_quote"` 的文字可以作为用户原话。

### 怎样在本地复测？

从仓库根目录运行下面两条命令，均使用独立的临时稿库。比较两个构建时，应使用相同脚本、字体和测试图片。

```sh
uv run --script crates/panache-mcp/tests/context_metrics.py target/release/panache-mcp
uv run --script crates/panache-mcp/tests/smoke.py target/release/panache-mcp
```

`context_metrics.py` 将 Python SDK 返回的工具清单、文本、结构化结果和图片响应重新编码成紧凑 UTF-8 JSON，报告字节数。`smoke.py` 通过真实 stdio 客户端验证改稿、版本冲突、重启恢复和导出等行为。

要查一次任务实际花了多少 token，应读模型客户端的用量记录，分开看未缓存输入、缓存输入和输出。一次 MCP 响应有多少字节、一次模型请求读入多少上下文、整份作业累计花多少 token，是三个不同的问题。长任务中，同一段会话历史可能随多次模型请求重复计入。
