# Dart 结构计量

从指定 Git 提交读取全部受跟踪的 `.dart` 文件。它可以回答一次重构是否减少了高分支函数、深层嵌套和长函数，也会列出仍然集中的位置。依赖仅属于此命令行工具。

## 运行

需要 Git 和 Dart SDK，项目复测采用 Dart 3.13.4。在仓库根目录执行：

```sh
cd scripts/dart-quality
dart pub get --enforce-lockfile
dart run bin/dart_quality.dart --repo ../.. --ref HEAD --top 5
```

缓存已有锁文件中的依赖时，可将安装命令换成 `dart pub get --offline --enforce-lockfile`。包依赖固定为 analyzer 10.1.0。

用同一份工具、SDK 和依赖比较两个提交。分支名会解析成完整提交编号并写入报告：

```sh
dart run bin/dart_quality.dart --repo ../.. --ref origin/main --json > before.json
dart run bin/dart_quality.dart --repo ../.. --ref HEAD --json > after.json
```

`--repo` 默认当前目录，可指向其他 checkout。`--ref` 默认 HEAD。读取对象库中的文件内容，工作区修改、未跟踪文件、构建缓存均不参与。为把重构前后的差异归于代码，请使用相同版本的工具。

## 如何阅读

- 按路径归入互斥分组。顶层 `vendor/` 优先归第三方；路径分量 `test/`、`tests/`、`integration_test/`、`test_driver/` 归测试；顶层 `tool/`、`tools/`、`scripts/` 归开发工具；其余归产品。
- 每个有实现的命名函数、方法、getter、setter、闭包，以及每个显式构造器各形成一个作用域。内层闭包有独立的分支和嵌套统计。
- 复杂度取一加决策数。每个 if、循环、三元表达式、catch、switch case、switch 表达式分支、when、短路操作符 `&&`、`||`、`??` 计一。集合里的 if/for 也计入。switch 语句的 default 不加，switch 表达式的通配分支计一。
- 嵌套深度取 if、循环、三元表达式、catch 和 switch 在作用域中的最大语法深度；else-if 依 AST 的嵌套计算。跨度包含从声明起始到结束两端的物理行、空行和嵌套声明，不能把各函数跨度相加当作代码行数。
- 终端按分组分别列出复杂度、嵌套和跨度的前 N 项。JSON 包含完整路径清单、每个作用域的数值与决策类型、各组计数、语法诊断、提交编号和工具版本。分组计数同时给出复杂度 ≥20/≥40、深度 ≥5、跨度 >100 行的作用域数。这些是同口径比较的筛选值。
- Dart 指标来自语法树，与 fuck-u-code 的 0–100 项目质量分量纲不同。类型检查、依赖解析和实际行为仍由 `flutter analyze` 与测试验证。

退出码 0 表示已跟踪 Dart 文件均已解析。缺少 Git、找不到仓库或提交、无 Dart 文件、非 UTF-8 文件、非普通 Git 文件或语法诊断均返回 1。若能读取 Git 树，JSON 的 `status` 为 `ok`、`empty` 或 `incomplete`；带诊断的文件保留在覆盖清单中，不产生函数度量。参数错误返回 64。
