# Panache 本地 MCP

通过支持 stdio 的 MCP 客户端把 Markdown 作业或诗稿排成手写页。文字整理使用工作台的 Markdown、LaTeX 和表格转换器。预览和导出都在本机调用同一个 Rust 引擎。

## 在桌面版连接 AI 客户端

完整解压或安装桌面版，打开「应用设置 → 连接 AI 客户端」即可复制本机的 JSON 配置。把它加入客户端的 MCP 配置，已有其他服务时合并 `mcpServers.panache`。客户端通过标准输入输出启动 Panache，关闭工作台后也能使用。移动安装目录后可重新复制。

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

使用自己的纸张时，在第一次调用 `save_section` 时传入 `paper_path`，例如 `{"markdown":"第一题","paper_path":"C:/作业/南昌大学横线纸.jpg"}`。路径指向运行 MCP 的电脑上的图片。工具使用工作台的识线和纠偏算法，并在返回的 `paper` 中给出实际页面尺寸、书写边距、行距和是否识别到横线。无可靠横线时保留底图，使用普通行距。纸张随稿件保存一次，后续追加、回查、预览和导出可在原图移动后继续使用。

可以对 agent 说：「用志莽行书给《钱塘湖春行》排一页，先让我看预览。确认后用同一版导出 PDF。」

| 工具 | 用法 |
| --- | --- |
| `list_fonts` | 列出本地可选的字体文件名。 |
| `save_section` | 用 `markdown` 新建稿件。首次可传标题、字体、字号、纸样、墨色、种子和作业排版模式。返回 `draft_id`、版本号和节号。 |
| `list_drafts` | 找回本地稿件和最新版本。每批 20 条，可传 `offset`。 |
| `read_section` | `summary` 取版本、长度和样式；默认 `excerpt` 隐去正文中已识别的内嵌图片数据；`source` 读取精确 Markdown。后两种视图按字符分页，默认 1000 字，单次最多 4000 字。 |
| `preview_handwriting` | 默认返回首页 PNG。用 `section`、`page` 查看指定节中的一页，两者从 1 开始。 |
| `export_handwriting` | 按节顺序导出整份稿件，返回绝对路径、版本和实际页数。格式可选 `pdf` 或 `zip`，ZIP 从 `0.png` 开始编号。 |
| `describe_controls` | 先列参数组，再按 `group` 查看单位、范围和枚举值。附上 `draft_id` 和 `revision` 可读取该版的实际值。 |
| `tune_handwriting` | 一次提交多项全稿参数，如 `{"ink_opacity":85,"word_spacing":2}`。`null` 恢复建稿时的设置。 |
| `adjust_glyphs` | 先用 `preview_handwriting(view="layout")` 取编号和坐标，再按同一节、页和版本调整选中字形。 |

面向 AI 客户端的调用示例、披露边界和测量口径见[工具设计](tool-design.md)。

长作业可以按题组或章节分次传入，每节从新页开始。需要连续排版的段落放在同一节，公式、表格、代码块也应完整放在一节内。追加时带上 `draft_id` 和上次返回的 `expected_revision`；修改已有节时再给出 `section`。另一位客户端抢先保存后，用 `read_section` 复核最新内容再提交。

每次保存只转换这一节，Markdown 原文和整理结果存入本地 SQLite。预览某节第 N 页时，引擎从该节开头排到第 N 页，只编码选中的一页。进程内保留最近生成的四张预览，修改其他节仍可复用。预览和导出传相同的 `revision` 可锁定稿件。种子和样式随稿保存，复现时需使用相同字体和引擎。

整稿上限为整理后 10 万字、200 页。完整导出只在调用导出工具时执行；客户端可以取消，提供进度令牌时可看到已完成页数。ZIP 逐页写盘，PDF 在内存中组装压缩页面后写盘。结果成功后才移入 `exports/`。稿件及历史持续保存在 `PANACHE_MCP_HOME`；Windows 默认是 `%LOCALAPPDATA%/Panache/mcp`，其他系统默认是 `$XDG_DATA_HOME/Panache/mcp` 或 `~/.local/share/Panache/mcp`。

## 验证

构建后可用官方 Python MCP 客户端跑一次 stdio 端到端测试。`--out` 可选，用于保留诗稿的预览和 PDF。

```sh
uv run --script crates/panache-mcp/tests/smoke.py target/release/panache-mcp --out output/pdf
```
