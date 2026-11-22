# AI 客户端如何调整手稿

## 工具发现

Panache 在 `tools/list` 中稳定公布九个任务入口。模型可以直接保存、预览、导出；只有需要调参时才调用 `describe_controls`。目录按排版、字体、墨迹、扰动和删除线五组组织，和服务端参数校验共用同一份定义。

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

全文样式变更后要重新定位字形；改写一节会让该节的旧字形调整只在旧版本生效。在其他节追加文字可以继续复用原节的调整。并发写入出现版本冲突时，先读取最新摘要，再决定是否重做补丁。当前 MCP 仅开放上述单字操作，工作台的透视变形和逐字着色仍由图形界面提供。

## 控制进入模型的内容

- 续接工作时，先用 `read_section(view="summary")` 查版本和长度。默认摘录保留图片说明，用 `attachment` 代替识别到的内嵌图片 URI。摘录的分页偏移针对摘录视图；精确恢复和改写正文应分页取 `view="source"`。后者可能包含原始图片数据。摘录不能作为原文覆盖保存。
- 参数目录按组返回。图片路径在建稿时由调用方提供；纸张快照和数据库保存在服务端。导出工具返回本机路径，客户端需要访问同一文件系统才能打开。
- 几何视图每批默认 12 个字形，上限 32，不传 PNG 或字形蒙版图集。查看第 N 页仍需从该节开头排到第 N 页。真正需要目测字迹时，再显式取图片视图。
- 客户端应把稿件、标题及工具响应中的用户文字作为数据处理。宿主负责选择工具、执行权限和会话历史。减少默认输出能节约上下文；明确请求原文、图片或路径的客户端仍能取得相应数据。

## 如何复测

从仓库根目录运行下列命令。两个脚本都使用独立临时稿库。比较版本时，把相同的测量脚本指向两个构建，使用相同字体与测试图片。

```sh
uv run --script crates/panache-mcp/tests/context_metrics.py target/release/panache-mcp
uv run --script crates/panache-mcp/tests/smoke.py target/release/panache-mcp
```

`context_metrics.py` 计算官方 Python SDK 返回对象重新序列化后的紧凑 UTF-8 JSON 字节数，包含文本和结构化结果。它记录工具清单、默认复查、摘要、单页图片与字框响应的大小，仅输出计数。该指标不计 JSON-RPC 外壳、宿主系统提示、缓存或模型 tokenizer，不能直接换算成模型账单。端到端测试另验证版本冲突、缓存、改稿后的编号失效、重启恢复，以及导出图像与同版预览像素一致。
