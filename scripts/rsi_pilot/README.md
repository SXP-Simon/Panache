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

## 七道跨题材作业

七个题面从纯文本延伸到分式推导、一个或两个表格、一个或两个带分支的流程图，以及表格、公式、流程图混排。作者只收到题目与支持语法的提示。保留其实际 Markdown 和工具返回的字形或图形位置，再与成稿相互核对。[题面、作者稿、单元格、节点与两组终止动作](results/content-matrix.json) · [从匿名 PNG 抄读的独立选票](results/content-blind-review.json)

从仓库根目录先构建 Markdown Worker、MCP 和用来核实结构的 Rust 示例。在新的实验目录运行下列命令。实时审题需要 Terra 可用；重新调用模型可能得到不同作答。独立评审和故意注错的题另外归档。

```sh
cargo build --locked --release -p handwriting-core --example rsi_content_probe
python scripts/rsi_pilot/content_matrix.py --out /tmp/panache-content freeze \
  --binary target/release/panache-mcp --worker app/web/prepare-text-worker.js --fonts assets/font_assets
python scripts/rsi_pilot/content_matrix.py --out /tmp/panache-content first
python scripts/rsi_pilot/content_matrix.py --out /tmp/panache-content review-v1
python scripts/rsi_pilot/content_matrix.py --out /tmp/panache-content review-v2
python scripts/rsi_pilot/content_matrix.py --out /tmp/panache-content deliver
python scripts/rsi_pilot/content_matrix.py --out /tmp/panache-content packets
python scripts/rsi_pilot/content_assessment.py /tmp/panache-content/packets /tmp/panache-content-blind
python scripts/rsi_pilot/content_matrix.py --out /tmp/panache-content results \
  --probe target/release/examples/rsi_content_probe --report /tmp/panache-content/report.json
```

这次七份初稿均获独立模型验收通过。对同一组像素，明确交付与暂缓两个动作的含义后，真正选定稿件由 2/7 增至 7/7。另外两道已知错误题保持图表数量，分别改错一个数据格和两个分支标签。模型均指出具体错处，修正稿与正确作者稿的 PNG 指纹完全相同。[两道注错题的原始判断与版本](results/content-controls.json) · [公开展示图清单](https://github.com/SXP-Simon/Panache/blob/7acd699ad5874d436edfee23a80761e22372a5dc/screenshots/rsi-pilot/content/index.json)

## 纸型、焦点与选样的补充检验

- 初始三个独立留出纸型中，一次生成、任务内修订、带 v2 经验的修订实际交付且模型验收通过的任务数分别是 1、3、1。以四分之一行距为阈值时，自由段落留空可能被错判；登记表填错整行又可能完全贴线。两个意图可用同一张图测试。[同像素双题意](results/row-intent-challenge.json) · [真人意见原文](results/human-feedback.json)
- v3 由宿主依据 v2 的错拒提出，先冻结再在两项新纸型任务上比较。两份初稿本来都合格，v2、v3 均交付且获独立模型通过，共使用 8 次、5 次模型决策。[每轮证据和模型用量](results/prospective.json)
- 单独测试照片上方 40% 的 132 个字形时，模型建议局部柔化 0.7 px。两页下部均为零像素变化。独立模型将局部稿和原稿并列；同强度的全局柔化使近处字迹显得过软。[同尺度比较与使用的 MCP 调用](results/appearance-trial.json)
- 既有局部编辑实验另留五道有已知答案的题。普通和细分评审提示均答对 5/5。回看这五题时，只复核一题，按变化像素最多会选到正确的移字稿，按“目标框仍有墨、模型却要求返工”的分歧会选到删错字的稿。该挑样规则属于事后分析，可用下一批失败稿检验。[逐题记录](results/review-calibration.json)

## 用户实拍原纸上的混排作业

这次使用 [首张开发纸的标注](paper_labels.json) 对应的原始 JPEG。它也是用户再次指定的附件。原纸、完整原尺寸页和分区盲审输入保存在运行目录，公开展示只取内页局部。不同纸张需要重新确定标注与裁区。以下命令从仓库根目录执行，沿用上文的 Markdown worker、字体、原生 MCP 和结构探针。Python 环境还需 Pillow、NumPy、OpenCV 和 PyMuPDF；实时验卷使用已登录的 Codex CLI。将 `PHOTO`、`RUN`、`MCP`、`WORKER`、`PROBE` 分别设为此次原照、新运行目录和对应的程序路径。

```sh
python scripts/rsi_pilot/real_photo_episode.py first --out "$RUN" --photo "$PHOTO" --binary "$MCP" --worker "$WORKER" --fonts assets/font_assets --probe "$PROBE"
python scripts/rsi_pilot/real_photo_episode.py guided --out "$RUN"
python scripts/rsi_pilot/real_photo_episode_controls.py --out "$RUN"
python scripts/rsi_pilot/real_photo_episode_repair.py unsupported --out "$RUN" --binary "$MCP"
python scripts/rsi_pilot/real_photo_episode_repair.py repair --out "$RUN" --binary "$MCP"
python scripts/rsi_pilot/real_photo_episode_challenge.py --out "$RUN" --binary "$MCP"
python scripts/rsi_pilot/real_photo_episode_report.py --out "$RUN" --results "$RUN/results"
python scripts/rsi_pilot/real_photo_episode_local.py --out "$RUN" --binary "$MCP" --results "$RUN/results"
```

- **首次是否主动检查。** [写前判断](results/real-photo-planning.json)直接给原照，一组另收到真实 MCP 初始化说明。[写后验卷、选稿和公式返工](results/real-photo-episode.json)保留主任务、原生页指纹、匿名决定、输入成本和导出核验。样稿本身和模型说过会检查什么分别留档。
- **局部光学和透视。** [原纸九区量测](results/real-photo-audit.json)给出纸面亮度、印线边缘宽度和行距。[四条件控件](results/real-photo-optical-controls.json)与[实际两版成稿的换位盲评](results/real-photo-native-pair.json)分别回答能否识别已知错位及实际改稿是否值得保留。[墨层作用范围](results/real-photo-finish-check.json)可用 `real_photo_finish_check.py --manifest "$RUN/manifest.json" --binary "$MCP" --out "$RUN/finish-check"` 重测。
- **只改一行。** [细粒度实验](results/real-photo-local-refinement.json)保留了模型建议、实验方的候选动作、正文改动像素、保护区和实际选定的 PDF 版本。该对照和主任务三选一是独立任务，各自保留了交付决定。

[原纸与初稿同位置](https://github.com/SXP-Simon/Panache/pull/70#issuecomment-7236162974) · [公式的真实拦截和修订](https://github.com/SXP-Simon/Panache/pull/70#issuecomment-7236214826) · [公开局部图库](https://github.com/SXP-Simon/Panache/tree/669a9db2c133edcd019e490156257b972dc72cac/screenshots/rsi-pilot/real-photo)
