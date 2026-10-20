# 桌面版

不想开浏览器、或者想要个能离线跑的本体，可以装桌面版。桌面版把后端和前端打包在一起，
双击就能用，不依赖网络。

## 下载

在本 fork 的 [Releases 页面](https://github.com/SXP-Simon/Panache/releases) 查找安装包，按系统和芯片选择。
若尚无所需平台的自用构建，请按下文从 `custom-base` 构建；上游安装包不代表本 fork 的功能。

| 系统 | 文件 |
|---|---|
| Windows | `.exe` 安装包（NSIS），或者免安装的便携版 exe |
| macOS（Apple Silicon） | `.dmg` |

## 应用内更新

发现新版本时会展示更新要点。点击「更新并重启」后，应用会下载、校验并准备恢复方案，保存草稿后退出，完成安装或替换并重新打开。正在生成时等待任务结束；选择稍后或保存失败不会强制退出。

Windows 当前用户安装版使用静默安装，便携版保留原 EXE 的备份；macOS 使用完整应用 ZIP 和同卷目录交换。新版只有在工作区、界面和后端均可用后才确认成功，启动失败会尝试恢复旧版。更新不会替换用户资料目录。

受管理员保护或只读的安装位置、系统信任许可、无法准备旧安装包或恢复入口等情况，需要按提示手动安装。macOS 仍可能要求系统许可，更新助手不会替用户绕过。较早版本尚无更新助手，需要先手动安装带助手的版本，之后才能使用完整自动流程。

!!! warning "只发 Apple Silicon 的 Mac 包"
    目前只构建 **arm64** 的 macOS 包，Intel Mac 装不了。
    Windows 包不受影响。

## macOS 首次打开被拦住

桌面版**没有 Apple 开发者签名，也没有公证**；构建时只做本地 ad-hoc 完整性签名，仓库里没有 Apple 开发者证书。所以下载后第一次打开，
macOS 会拦下它。在 macOS 15 及以上，提示可能直接说**「文件已损坏」**。

**这个提示有两种可能，先分清楚是哪一种：**

- 多数情况是**隔离属性** —— 系统会给任何下载来的文件打上这个标记，未签名的应用一打开就会撞上，
  文件本身没坏。
- 也可能是**文件真的损坏，或者被人改过**。从非官方渠道拿到的安装包尤其要警惕。

所以要**先确认安装包是从本仓库的 [Releases 页面](https://github.com/SXP-Simon/Panache/releases) 下载的**。
确认来源无误，再用下面的方式放行；**来源存疑就不要绕过这个提示，也不要打开它**。

确认之后，在终端里执行一次：

```shell
xattr -dr com.apple.quarantine /Applications/Panache.app
```

或者去「系统设置 → 隐私与安全性」，在提示里点**「仍要打开」**。

这两种方式可以让系统不再拦这个应用。它们之所以必要，只是因为项目没有 Apple 开发者证书去签名和公证，
**并不代表这个包一定安全** —— 所以上面那句「先确认来源」不是客套话。

## 和在线版有什么不同

桌面版使用同一份 React 前端和 Python 渲染服务，主要区别是：

- **本机生成** —— 无固定 10 页截断，仍受内存、纸张尺寸和机器性能约束。
- **禁用错误上报** —— 桌面运行环境禁用 Sentry；前端不加载统计或客服脚本。
- **不联网下载 pandoc** —— 没有 pandoc 时用 `python-docx` 处理 `.docx`。
- **不受过载保护干扰** —— CPU 占用守卫被放开，本机不至于请求自己都被 429 拦掉。

## 数据放在哪

任务数据库、临时文件、日志和字体都在用户数据目录里，删掉就等于恢复出厂：

| 系统 | 位置 |
|---|---|
| Windows | `%LOCALAPPDATA%\HandwritingWeb` |
| macOS | `~/Library/Application Support/HandwritingWeb` |

里面大致是：

- `tasks.db` —— 任务队列（SQLite）
- `temp/` —— 渲染出来的图片
- `logs/` —— 日志
- 字体
- `studio/` —— 编辑器草稿、预设与上传资源，独立于后端任务的有效期

## 自己构建

构建脚本要按**当前平台**跑 —— PyInstaller 不能交叉编译，Windows 包只能在 Windows 上出，
macOS 包只能在对应架构的 Mac 上出。

```shell
bash desktop/build.sh                 # 完整构建：前端 → 后端可执行文件 → 安装包
bash desktop/build.sh --app-only      # 只出 Electron 目录版，不生成安装包
PYTHON=python bash desktop/build.sh   # 指定解释器（CI 用）
```

产物在 `desktop/build/`。开发调试时先 `--app-only`，再在 `desktop/` 下 `npx electron .` 直接跑。

开发约定见仓库根的 [`AGENTS.md`](https://github.com/SXP-Simon/Panache/blob/custom-base/AGENTS.md)，
存储与退出保存见[架构说明](architecture.md)。修改构建、安全或跨平台行为时，以相应源码和测试为准。
