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

## 从普通作业学习单条经验

一次独立模型会话只收到用户作业和 Panache MCP。每次使用新的工作目录和会话；可复用的内容留在同一 Panache 数据库。代理转发真正的 stdio 消息，保留模型调用参数、原生回执和图片摘要。它不会代模型提交经验。验证任务由实验程序安排。

- 一道语文抄写顺利交付，宿主保留零条。另一道物理作业有表格、两行照抄用的旧命令、两处误排的分式。Astra 修完后把两个现象归纳成了一条动作，关联修前和交付版的检查单。最终聊天回复只提到了作业改动。[抄写题](results/experience-plain.json) · [物理题逐步记录和候选原文](results/experience-source.json) · [同页两版截图](https://github.com/SXP-Simon/Panache/pull/70#issuecomment-7236947200)
- 第一次验证混淆了“眼前的初稿是否要修”和“修完能不能交”，导致原候选被错误拒绝。原库保留该拒绝。后续正例在两个真实版本上分别盲判；边界题单问当前页是否需要改变。[误拒及两次独立读图](results/experience-evaluator-error.json)
- 在新库用同一题面重新做作业，Astra 按照自己的实际返工拆出三条。分式改写引用 r1、r2、r4，速度单位引用 r1、r4，分母避开横线引用 r2、r4。三条分别有 ID。验证实验只推进分式改写，另两条仍是候选。[三条原文、像素和最终交付回复](results/experience-three-rules.json)
- 新的 Terra 会话按化学作业标签查询，只命中分式改写。它保留供照抄的旧命令，把显示行排成 3/24 × 100% = 12.5%，复核后导出。另一个模型从 PDF 内嵌页读回分数和百分数。相同标签下仍待验证或已经失败的规则均未返回。[所有会话、逐题判定和图片摘要](results/experience-cross-session.json) · [修前与交付图](https://github.com/SXP-Simon/Panache/pull/70#issuecomment-7237004841) · [验证题图板](https://github.com/SXP-Simon/Panache/blob/c3f52ad98484755cc7f8479e358b47c4c76a2202/screenshots/rsi-pilot/atomic-experience/experience-verified-examples.png)
- 运行独立会话需要能访问所选模型的 Codex CLI。配置 JSON 含 `binary`、`worker`、`fonts`、`home` 四个绝对路径，分别指向 MCP 可执行文件、Markdown worker、字体目录和本次实验的专用数据目录。用新目录复现普通物理作业：`python scripts/rsi_pilot/experience_mixed.py --config config.json --out run`。新运行会有自己的稿件、模型判断和规则 ID。
- 单独验证检索和撤回的存储语义可执行 `uv run --script crates/panache-mcp/tests/experience_visibility.py /path/to/panache-mcp`。该测试覆盖同一作业提出两条、独立样本验证、相同标签下的可见性、失效后跨连接隐藏，以及新会话按检查单回查原像素。它使用受控输入，宿主自主决策的实测另见逐题记录。

## 中文题面的 BM25 对照

同一份隔离库中有三条生效经验、三条候选和一条已被反例否决的经验。旧模板分式经验来自上面的真实跨会话实验。另两条由实验方依据错格和错分支案例拟定，分别用原生正例修订和正确边界页核对后登记。六份中文题面依次跑原话、人工选择的标签、原话加标签三种查询。报告包含完整的原话、返回顺序及四条隐藏规则的精确文本探针。[逐题查询与真实宿主回执](results/experience-bm25.json)

三个新 Terra 会话分别收到化学、表格和流程图作业，首次调用均用题面原话查经验。化学首题缺少要逐字保留的旧命令，宿主在命中后向用户询问。补齐命令后又用新会话跑了一次，导出保留源码及 12.5% 的 PDF。纯文字负例写有“勿加公式、图或表”，仅用 BM25 返回两条无关候选，加题目标签后为空。这是词面召回，使用前仍需核对适用条件。[三份交付和验证页](https://github.com/SXP-Simon/Panache/tree/427a03c26f29ba2dea6960111ceb488d1836ad13/screenshots/rsi-pilot/bm25)

复现实验可用 `experience_bm25.py`，其 `--original` 指向上一节三条提案已分别完成验证和对照的 physics-02 数据目录。配置沿用 `binary`、`worker`、`fonts`、`home`，其中 `home` 指向新的隔离目录。依次运行 `prepare`、核对输出的原生页面、`validate`、`compare`；每次加上 `--config config.json --out run`。用 `session --case chemistry|table|flow|chemistry_template` 分别运行四个宿主，再用 `report --result report.json` 汇总。每个会话复制同一个已验证的起始库。
