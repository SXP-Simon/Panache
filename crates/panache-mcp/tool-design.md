# AI 客户端如何调整手稿

## 工具发现

Panache 在 `tools/list` 中稳定公布九个任务入口。模型可以直接保存、预览、导出；只有需要调参时才调用 `describe_controls`。目录按排版、字体、墨迹、扰动、删除线和拍摄信息六组组织，和服务端参数校验共用同一份定义。

MCP 的工具列表支持分页。客户端可能取完所有页；分页能控制单次协议响应大小。Claude 的 Tool Search 支持宿主配置延迟加载，实际进入模型上下文的工具由宿主决定。Panache 的 stdio 客户端也可以完全不提供搜索，只用标准工具列表和调用接口。项目目前选择按需查询参数，避免为小型目录引入搜索索引和额外的调用步骤。设计依据见 [MCP 工具规范](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)、[MCP 路线图中的渐进发现](https://blog.modelcontextprotocol.io/posts/mcp-roadmap/) 和 [Claude Tool Search 文档](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)。

## 一次调整

假设要把墨色调淡，再把第二页的一处字迹右移。如果有稿件 ID，只需要保存 ID、当前版本和相关节号；省略 ID 时可以用 `list_drafts` 找回稿件。以下调用中的版本号用于示例，实际应使用工具返回的版本。

| 调用 | 参数示例 | 模型拿到的结果 |
| --- | --- | --- |
| `describe_controls` | `{"group":"ink","draft_id":"…","revision":5}` | 墨迹控件的类型、范围、单位和该稿当前值 |
| `tune_handwriting` | `{"draft_id":"…","expected_revision":5,"changes":{"ink_opacity":85}}` | 新版本 6 |
| `preview_handwriting` | `{"draft_id":"…","revision":6,"section":1,"page":2,"view":"layout","limit":12}` | 原始字框、编号、已有调整和下一批偏移量 |
| `adjust_glyphs` | `{"draft_id":"…","expected_revision":6,"section":1,"page":2,"ids":[37],"dx":4}` | 新版本 7；示例编号 37 须替换为本页实际编号 |
| `preview_handwriting` | `{"draft_id":"…","revision":7,"section":1,"page":2}` | 单页 PNG |
| `export_handwriting` | `{"draft_id":"…","revision":7,"format":"pdf"}` | 整稿 PDF 的本机路径和页数 |

字号、行距和页边距以纸张原始像素为单位。照片底纸采用识别后的画布尺寸；边距和行距可手动微调。所有参数先合并再校验，因此可以在同一补丁里同时增加字号和行距。位移相对原始字框，`dx:4` 表示向右 4 px；后续只传 `dy` 会保留原有 `dx`。精修还支持缩放、旋转和浓度。字框为 `[x,y,width,height]`。遇到公式、插图或归一化导致源码无法准确对应时，模型可以结合可视预览和坐标定位。

全文样式变更后要重新定位字形；改写一节会让该节的旧字形调整只在旧版本生效。在其他节追加文字可以继续复用原节的调整。并发写入出现版本冲突时，先读取最新摘要，再决定是否重做补丁。MCP 还可以用 `shape` 对选中字形做剪切或梯形变换。也可对选中字形指定局部墨色。

## 插图墨迹

在 `preview_handwriting(view="layout", illustrations_only=true)` 查询本页插图。结果中同一 `illustration_id` 下，`illustration` 表示框线、箭头等剩余笔迹，`illustration_detail` 表示可独立选择的连通笔迹区域。用坐标与单页图像对应标签。改变整个图的墨迹时，把同组编号放进同一次调用，每图最多 32 项。

例如对一个标签调用 `adjust_glyphs`，传 `thickness: 0.5` 增加 0.5 px 笔画粗细，也可同时传 `softness: 0.2`、`opacity: 85` 或 `color: "#304458"`。粗细和柔化以 0.1 px 为单位；归零恢复原始插图笔迹，墨色用 `inherit` 恢复。图内文字来自导入的像素；标签与框线粘连、笔迹太密时，会保留为整体。

## 照片和纸面坐标

导入 `paper_path` 时，默认 `paper_mode="photo"` 在原照片上合成笔迹和插图。`flatten` 保存校平后的底纸。建稿结果只返回尺寸、边距、行距和识别方式。遇到置信度不足的照片会返回 `alignment="unverified"`。稿件保留建稿时的纸张快照，后续版本可在同一底图上重新校准。

| 模型可以取得或指定的内容 | 对应接口 |
| --- | --- |
| 单独查看稿件底纸、或查看任意一页的成品 | `preview_handwriting(view="paper")`、`view="image"`。两者按需返回图片 |
| 照片上的字形位置与横线方向 | `view="layout"`。投影稿的 `photo_quad` 为基础字框左上、右上、右下、左下四角，`photo_baseline` 为基线两端。单位是成品照片像素。已有的单字调整另列在 `adjustment` |
| 按自己观察到的横线定位版心 | 建稿时传 `paper_guides`。每项含 `row`、`left:[x,y]`、`right:[x,y]`，坐标取自原图。第 0 行和最后一条可写行决定范围，中间可再给参考行。两行间按宽度变化插值 |
| 改一组字的局部形状 | `adjust_glyphs` 的 `dx/dy` 使用投影前的纸面坐标。`shape:{"shear_degrees":4,"top_width_percent":94}` 让字底向右倾并略微收窄字顶。`{"shear_degrees":0,"top_width_percent":100}` 恢复默认形状 |

整页投影已经包含纸面的斜度和远近变化。局部形变叠加在纸面投影之前。选择检查哪页、是否精修，由客户端根据图像决定。

## 控制进入模型的内容

- 续接工作时，先用 `read_section(view="summary")` 查版本和长度。默认摘录保留图片说明，用 `attachment` 代替识别到的内嵌图片 URI。摘录的分页偏移针对摘录视图；精确恢复和改写正文应分页取 `view="source"`。后者可能包含原始图片数据。摘录不能作为原文覆盖保存。
- 参数目录按组返回。图片路径在建稿时由调用方提供；纸张快照和数据库保存在服务端。导出工具返回本机路径，客户端需要访问同一文件系统才能打开。
- 几何视图每批默认 12 个字形，上限 32，不传 PNG 或字形蒙版图集。查看第 N 页仍需从该节开头排到第 N 页。真正需要目测字迹时，再显式取图片视图。
- 客户端应把稿件、标题及工具响应中的用户文字作为数据处理。宿主负责选择工具、执行权限和会话历史。减少默认输出能节约上下文；明确请求原文、图片或路径的客户端仍能取得相应数据。

## 复盘证据与版本轨迹

`view="review"` 按需返回三张按相同比例缩放的图片。橙色边界和青色参考线来自书写区估计，叠图可与裸底纸对照。在原分辨率比较显示在纸上的墨迹和底纸，按图像上中下三等分统计 RGB 任一通道变化至少 8 级的像素及落在参考区外的数量。在抽样字形调整后的基线中点附近搜索底纸的局部暗线并报告垂直偏差中位数和支持样本数；校徽或背景纹理也可能给出暗线，无足够对比时返回空值。短文自然可能只覆盖上部。对有正文的页面，零像素变化是重新检查的明确信号。没有自动审美评分，验收时仍要查看原图，必要时请用户指出具体位置。

轨迹按稿件和版本保存在本机。修改操作与简短备注在同一事务提交，同一版本、节、页只保留一份复盘指标。查询不会返回原文、字体数据、图片字节或完整对话。这里的轨迹指已执行的动作和可复查的结果。模型可以对照前后版本调整下一步；没有修改模型权重或自动跨用户积累经验。

该设计借鉴了 Reflexion 将任务反馈留给下一次尝试的做法。关于模型仅靠自我判断纠错的研究使用的是推理任务，本项目将其作为设计动机。这里的效果由本项目的图像样本和回归用例单独验证。[Reflexion（NeurIPS 2023）](https://proceedings.neurips.cc/paper/2023/hash/1b44b878bb782e6954cd888628510e90-Abstract-Conference.html) · [外部反馈与自我纠错（ICLR 2024）](https://proceedings.iclr.cc/paper_files/paper/2024/hash/8b4add8b0aa8749d80a34ca5d941c355-Abstract-Conference.html)

SICA 将历次尝试及其评估结果放入档案，供下一轮决策参考。本工具采用了可按版本取回结果的做法，作用域限于当前稿件，修改对象是稿件与排版参数。[SICA 作者实现](https://github.com/MaximeRobeyns/self_improving_coding_agent)

## 如何复测

从仓库根目录运行下列命令。两个脚本都使用独立临时稿库。比较版本时，把相同的测量脚本指向两个构建，使用相同字体与测试图片。

```sh
uv run --script crates/panache-mcp/tests/context_metrics.py target/release/panache-mcp
uv run --script crates/panache-mcp/tests/smoke.py target/release/panache-mcp
```

`context_metrics.py` 计算官方 Python SDK 返回对象重新序列化后的紧凑 UTF-8 JSON 字节数，包含文本和结构化结果。它记录工具清单、默认复查、摘要、单页图片与字框响应的大小，仅输出计数。该指标不计 JSON-RPC 外壳、宿主系统提示、缓存或模型 tokenizer，不能直接换算成模型账单。端到端测试另验证版本冲突、缓存、改稿后的编号失效、重启恢复，以及导出图像与同版预览像素一致。
