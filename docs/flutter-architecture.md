# Flutter/Rust 客户端架构

## 运行边界

`app/lib/screens/` 负责页面、输入焦点、导航和文件选择交互；`app/lib/models/settings.dart` 管理渲染参数、校验与请求字段。`app/lib/services/workspace.dart` 是工作区业务协调器，对 UI 暴露草稿、设置、连接、任务与导出状态，通过 `ChangeNotifier` 通知变化。

`HandwritingApi` 是生成服务契约。移动端实现使用 Rust C ABI / Dart FFI，桌面端连接受令牌保护的本地 sidecar，Web 连接 HTTP 服务。界面不直接调用 FFI、轮询任务或写入偏好设置。

## 页面与组件职责

`app/lib/screens/workbench.dart` 保留界面导航状态、输入控制器、异步操作协调和快捷键入口，通过明确参数及回调组合独立组件；组件不访问父页面的 State，也不通过 part 或 extension 共享私有状态。

| 模块 | 职责 |
|---|---|
| `widgets/workbench_shell.dart` | 自适应 AppBar、桌面导航栏、移动底部导航与应用设置菜单 |
| `widgets/workbench_layout.dart` | 编辑/参数/预览的响应式布局、错误和任务进度、全局生成与取消入口 |
| `widgets/workbench_editor.dart` | 编辑器、焦点与撤销控制器接入、字符数及插图缩略图 |
| `widgets/workbench_controls.dart` | 通用面板和有图标、名称及用途说明的编辑工具菜单 |
| `widgets/workbench_settings.dart` | 参数校验与输入、字体/背景/预设动作呈现，文件和网络操作回调给页面 |
| `widgets/workbench_preview.dart` | 图片预览、缩放、分页和保存动作呈现 |
| `widgets/workbench_information.dart` | 使用说明、项目来源及本地数据说明 |
| `screens/dialogs/` | 连接设置、Markdown/书信输入及数学预览对话框，返回用户选择而不直接操作工作区 |

界面局部导航、面板选择和文本光标由页面持有；渲染参数与任务状态由业务层持有。移动端工具菜单同时显示图标、动作名和用途说明；长任务的取消入口位于全局任务区域，不要求先切换到预览页。键盘弹出时隐藏底部导航及导出操作，保留显式收起键盘入口。

## 草稿与生命周期

移动端通过平台入口注入 `Settings.notebook` 默认工厂：竖版作业本目标约每行二十汉字、十六行；实际容量随所选字体变化。恢复草稿时保存字段优先，默认重置仍使用本平台工厂。桌面与 Web 使用普通默认工厂，业务工作区不直接读取操作系统类型。

`WorkspaceDocuments` 承担文档导入、预设序列化和背景检测，页面只接入系统文件选择与保存。缺失的预设字体保留当前字体，替换背景后的迟到检测结果不回写参数。

`WorkspaceStorage` 是可注入持久化接口；默认 `PreferencesWorkspaceStorage` 使用 SharedPreferences。`flutter.workspace` 保存文字、参数及插图映射，`flutter.preset` 保存参数预设，`flutter.api` 保存自定义 HTTP 服务地址。内置字体选择随参数保存，重连时按字体名称恢复，字体不存在时回退到可用字体。上传字体通过独立的 `UploadedFontStorage` 保存：原生端写入应用支持目录，Web 写入 IndexedDB；草稿只记录是否使用上传字体，字体二进制不写入 SharedPreferences。移除上传字体或改选内置字体会同步清除保存的上传文件。背景文件与生成图片仍是会话资源。

`Workspace.edit()` 延迟 400 ms 保存；`persist()` 立即捕获当前快照并加入串行写入队列，后写快照不能被较慢的旧写覆盖。移动应用进入 inactive、paused 或 detached 时由页面调用 `persist()`；`dispose()` 也提交最后快照并关闭 API。操作系统强制结束进程无法保证执行 Dart 清理回调，主动生命周期保存用于减小丢失窗口。

恢复草稿时按字段校验类型，损坏设置或插图条目不会清空其它可读内容。持久化实现可在测试中替换为内存实现，覆盖写入顺序、失败恢复和退出保存。

## 任务与资源

生成任务有独立代次。提交、状态查询、预览和导出返回后都确认该代次仍有效；取消、销毁后的迟到响应不能覆盖界面，也不能清除后续任务的 busy 状态。引擎支持取消时，提交尚未返回也可先取消，待任务 ID 返回后补发取消。

连接探测也使用独立代次，旧服务的迟到响应不能覆盖新连接。生成期间不替换 API。关闭工作区会关闭客户端并释放图片、上传文件和导出字节引用。预览保留上一份成功结果，新的生成失败或取消时仍可查看。

## 扩展约定

界面局部状态留在组件；跨区域业务状态放入工作区，纯文本与数学转换放在 `utils/`，持久化放在存储适配器。新增服务能力通过 API 契约适配各平台，避免在 UI 中按操作系统复制业务逻辑。任务相关测试使用可控制 Future 的 API 替身验证异步顺序；公式转换同时验证 Dart 与 Rust 实现及真实引擎输出。

数学转写的语义边界、课程测试和可复查图集入口见[数学支持与验证](math-support.md)。
