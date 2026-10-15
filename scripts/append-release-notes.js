#!/usr/bin/env node
/**
 * 往 GitHub Release 正文末尾追加「哪个机器该下哪个包」的说明。
 *
 * 为什么不写成 release-notes-generator 的输出：那段说明只对 Release 页面有意义，
 * 挂在 notes 上会跟着 @semantic-release/changelog 一起写进 CHANGELOG.md，于是每次
 * 发版的历史记录里都重复一遍装包指南。
 *
 * 由 release.config.js 里 @semantic-release/exec 的 successCmd 调用 —— 用 success
 * 而不是 publish，是因为 success 阶段跑在所有 publish 之后，这时
 * @semantic-release/github 一定已经把 Release 建好了，不必依赖插件数组的顺序。
 *
 * 用法：node scripts/append-release-notes.js v1.33.0
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

// 幂等标记：补跑或手动重跑时靠它判断正文里是否已经有这段说明
const MARKER = "<!-- download-guide -->";

const tag = process.argv[2];
if (!tag) {
  console.error("用法: node scripts/append-release-notes.js <gitTag>，例如 v1.33.0");
  process.exit(1);
}
const version = tag.replace(/^v/, "");

function gh(args) {
  // Forks may default gh to the parent repository; always resolve this checkout's origin.
  const origin = execFileSync("git", ["remote", "get-url", "origin"], { encoding: "utf8" }).trim();
  const repository = process.env.GITHUB_REPOSITORY || origin.replace(/^.*github\.com[:/]/u, "").replace(/\.git$/u, "");
  if (!/^[\w.-]+\/[\w.-]+$/u.test(repository)) throw new Error("无法确定当前发布仓库");
  return execFileSync("gh", [...args, "--repo", repository], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
}

const section = `${MARKER}
## 下载哪个包

构建完成后，安装包会出现在本页下方的 Assets。Release 创建时构建可能仍在进行；仅下方实际出现的文件可下载。GitHub 自动提供的 Source code 是源码，不是可运行的客户端。

### Electron 桌面版

沿用 Web 界面的桌面客户端：

| 你的机器 | 下载这个 | 说明 |
| --- | --- | --- |
| Windows | \`HandwritingWeb-Setup-${version}.exe\` | **推荐**。安装版，可选安装位置，装完有桌面与开始菜单快捷方式 |
| Windows | \`HandwritingWeb-portable-${version}.exe\` | 免安装便携版，双击直接运行 |
| Mac（Apple 芯片，M1 及以后） | \`HandwritingWeb-${version}-arm64.dmg\` | 挂载后把 \`HandwritingWeb.app\` 拖进「应用程序」 |
| Mac（Apple 芯片，M1 及以后） | \`HandwritingWeb-${version}-arm64.zip\` | 同一个 App 的压缩包，DMG 打不开时用这个 |

### Flutter 客户端

Flutter 界面与 Rust 离线渲染引擎，与上面的 Electron 客户端分开打包。按设备选择一套客户端即可：

| 你的机器 | 文件名 | 使用方式 |
| --- | --- | --- |
| Windows x64 | \`Flutter-HandwritingWeb-${version}-windows-x64.zip\` | 解压整个目录后运行应用，保留同目录的资源与后端 |
| Linux x64 | \`Flutter-HandwritingWeb-${version}-linux-x64.tar.gz\` | 解压整个目录后运行应用，需桌面 GTK 运行环境 |
| Mac（Apple 芯片） | \`Flutter-HandwritingWeb-${version}-macos-arm64.zip\` | 解压后将其中的 App 拖入「应用程序」 |
| Android 手机（优先选择） | \`Flutter-HandwritingWeb-${version}-android-arm64-v8a.apk\` | **推荐普通手机用户下载**，适用于 64 位 ARM 手机 |
| Android x86_64 | \`Flutter-HandwritingWeb-${version}-android-x86_64.apk\` | 适用于 x86_64 模拟器或设备，普通 ARM 手机请选择上面的 v8a 包 |

Android 首次从旧调试版切换时，如提示签名冲突，需先卸载旧版（卸载会删除应用数据）；后续正式版沿用同一签名更新。
两套桌面客户端目前都不提供 Intel Mac 包；iOS 尚无可直接安装的发布包。
Flutter 构建与上传进度见仓库 Actions 的 **Flutter Release Assets**；任一平台失败时可能暂时没有 Flutter 包。
\`Flutter-source.json\` 和每个 Flutter 包旁的 JSON 是源码提交、版本与 SHA-256 校验信息，不是安装包。

### macOS 首次打开会被拦下（正常现象）

这个包没有 Apple 开发者签名，也没有公证，所以 macOS 会拦。macOS 15 起提示的是
「已损坏，无法打开」—— 那不是真的损坏，是下载时被系统加上的 quarantine 属性。
Electron 安装到默认位置后可执行：

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/HandwritingWeb.app
\`\`\`

Flutter 请将命令中的路径替换为实际安装的 App 路径。

不想用命令行也行：被拦一次之后去「系统设置 → 隐私与安全性」，在下方的提示里点「仍要打开」。
`;

function main() {
  const raw = gh(["release", "view", tag, "--json", "body", "--jq", ".body"]);
  // 正文为空时 --jq .body 会给一个字符串 "null"
  const body = raw.trim() === "null" ? "" : raw;
  // 2026-10-15：替换受管区段，允许更新模板并保留其后的人工说明。
  const start = body.indexOf(MARKER);
  const closing = "<!-- /download-guide -->";
  const end = start < 0 ? -1 : body.indexOf(closing, start);
  const prefix = start < 0 ? body : body.slice(0, start);
  const suffix = end < 0 ? "" : body.slice(end + closing.length);

  // gh release edit 没有 --notes-append，只能把拼好的整段正文写回去
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "release-notes-"));
  const file = path.join(dir, "body.md");
  fs.writeFileSync(file, `${prefix.trimEnd()}\n\n${section}<!-- /download-guide -->${suffix}`.trimEnd() + "\n", "utf8");
  try {
    gh(["release", "edit", tag, "--notes-file", file]);
    console.log(`已把「下载哪个包」追加到 ${tag}`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

try {
  main();
} catch (error) {
  // 故意只告警、不退出非零：这纯粹是展示文案，失败不该让发版变红。而且
  // desktop_release.yml 的预检要求 semantic-release 的 conclusion == 'success'，
  // 在这里失败会连带把 Windows / macOS 桌面包一起跳过，代价远大于少一段说明。
  console.error(`!! 追加下载说明失败（不影响发版与桌面包上传）：${error.message}`);
}
