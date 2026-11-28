# 用照片作业检验宿主的看图决策

这里有两个入口。固定动作回放用于复核渲染和版本选择；实时实验让 Codex Terra 根据返回的图片自行决定索证、修改、交付或暂缓。用户提供的私有照片按 SHA-256 匹配，公共方格纸和渐变模糊透视纸从代码生成。任务、动作和成稿指纹分别保留，方便更换决策模型后重新比较。

## 在新目录重放公开数据

从仓库根目录运行。先按 [MCP 构建说明](../../crates/panache-mcp/README.md) 构建 Worker 和二进制。以下示例使用 Bash，Windows 在可执行文件名后加 `.exe`。

```sh
uv run --with pillow --with numpy python scripts/rsi_pilot/replay.py \
  --binary target/release/panache-mcp --worker app/web/prepare-text-worker.js \
  --fonts assets/font_assets --out /tmp/panache-public-replay
```

该命令从作业原文与生成的纸张建稿，重放 [决策原文](results/decisions.json)，核对每个候选版本的全部 PNG 指纹和结局。每个修订目录保存成品、原生局部、参考线和布局数据。输出根目录的 `replay.json` 列出逐组结果。固定动作回放检验 MCP 能否做出同样的稿件；重新调用模型才能检验它会不会作同样的选择。

## 运行一个真正的模型任务

以下命令假设同一环境中已安装 Pillow、NumPy，且 Codex CLI 已登录并可调用 Terra。先准备目录，绑定任务，然后启动宿主。模型可用的编辑动作与检查预算在 [宿主循环](run_episode.py) 中。比较两种策略时保持宿主、种子、字体和每题预算一致。

```sh
python scripts/rsi_pilot/benchmark.py --out /tmp/panache-live setup \
  --binary target/release/panache-mcp --worker app/web/prepare-text-worker.js \
  --fonts assets/font_assets public-depth
python scripts/rsi_pilot/benchmark.py --out /tmp/panache-live native-start public-depth B \
  --binary target/release/panache-mcp --provider gpt-6.1-terra
python scripts/rsi_pilot/benchmark.py --out /tmp/panache-live baseline public-depth B
python scripts/rsi_pilot/run_episode.py --out /tmp/panache-live --paper public-depth --arm B
```

每个 `turn-N` 保存提供给模型的指令、图片指纹、原始 JSON 决定及 Codex 报告的 token。每个 `step-N` 保存工具实际执行的结果。程序检测横线只读取空白纸，独立的评测标注在流程结束后才进入评分。宿主传给模型的纸纹测量是估计值。用户意图决定空行能否跳过，测量与成稿的冲突应单独记录。

从开发任务形成策略候选时，在 `publish_rsi_policy` 中传入实际完成的开发任务编号、父版本及新规则。使用 `native-start … --policy <新策略编号>` 为其他纸张创建新任务。结束后将独立留出验证通过 `validate_rsi_policy` 归档。该服务保留宿主报告的来源；资料是否属于不同纸型，以及模型判读是否可信，需要用数据集分组和盲评核实。本次 v2 的真实来源是两张本地开发照片。公开回放保留已发表的谱系和动作，新的在线实验需要提供自己的开发记录。

## 读本次证据

- [实验约定与验收依据](../../crates/panache-mcp/tests/rsi_pilot/PROTOCOL.md) 提取了原 MCP 的贴线、取局部图与检查导出版本等提示。
- [逐页测量](results/measurements.json) 包含内容指纹、覆盖率、对齐、原图与墨迹对照、PDF 检查和分阶段的工具调用。页面是同一份稿的重复观测。
- [独立视觉选票](results/blind-review.json) 按任务和成稿像素去重，保留判断理由、可交付数和严重错放数。暂缓时另审最后一个候选稿，统计实际交付时仍计为零。
- [局部评审校准](results/review-calibration.json) 对照既有合成局部编辑的已知答案。对齐正确、文字仍可读、用户本人喜欢这种风格是三个不同的问题。
- 图片、每轮结论和未达到预期的结果记在 [实验 PR](https://github.com/SXP-Simon/Panache/pull/70)。公开图像固定在 [pr-assets 的截图清单](https://github.com/SXP-Simon/Panache/blob/796eb2c58c1147a4e2c1cdae94c9911ae1f519f3/screenshots/rsi-pilot/index.json)。
