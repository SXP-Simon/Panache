# [1.7.0](https://github.com/SXP-Simon/Panache/compare/v1.6.0...v1.7.0) (2026-10-20)


### Bug Fixes

* **fe/src/features/updates:** 精简面向用户的更新提示与摘要 ([2c6e662](https://github.com/SXP-Simon/Panache/commit/2c6e662b85fb320b9369e1412a1c2dc37b2a2b06))
* **scripts:** 校验并发布 Android 更新所需的实际版本码 ([47d0fc3](https://github.com/SXP-Simon/Panache/commit/47d0fc3a87d872b55e31c434d78839f04abd525c))


### Features

* **desktop:** 安全检查下载并打开匹配平台的更新 ([faeb086](https://github.com/SXP-Simon/Panache/commit/faeb086e44f456643c2476cb5b9775a92f1d5ebd))
* **fe/src/features/updates:** 发现新版时展示更新日志弹窗 ([d76410e](https://github.com/SXP-Simon/Panache/commit/d76410ec7694a49a4d2ec4f4999bf0a42a791c41))
* **fe/src/features/updates:** 提供更新设置与保存后部署刷新 ([7c288ec](https://github.com/SXP-Simon/Panache/commit/7c288ec86de058f7173dfe5533da6295e1d04c46))

# [1.6.0](https://github.com/SXP-Simon/Panache/compare/v1.5.0...v1.6.0) (2026-10-20)


### Bug Fixes

* **be:** 为手写表格补齐完整单元格网格 ([c7d3320](https://github.com/SXP-Simon/Panache/commit/c7d332037304860a08dec2d8bf5b32cd69973154))
* **be:** 保留表格单元格内的分隔符与转义文本 ([1b3e7c5](https://github.com/SXP-Simon/Panache/commit/1b3e7c56a7972cf18ccadfd383e9323644d2c3e7))
* **be:** 将分布律表格绘制为二维手写结构 ([12a7977](https://github.com/SXP-Simon/Panache/commit/12a7977eea05479f5587c62d903b718fc168fb3e))
* **be:** 统一手写表格格线与单元格对齐 ([4cbab6c](https://github.com/SXP-Simon/Panache/commit/4cbab6c2943dd17230c97ff389007428a2ac80e8))
* **fe/src/utils:** 保留供二维手写绘制的表格结构 ([131a0ea](https://github.com/SXP-Simon/Panache/commit/131a0ea23ef12e8c9a6c99c31beb48777a979855))
* **fe/src/utils:** 安全转写含分隔字符的表格单元格 ([23562c7](https://github.com/SXP-Simon/Panache/commit/23562c7b86dbbba9f492bcd0f5a64fb814f09657))
* **fe/src/utils:** 转写带分隔线的数组与框选公式 ([21bf709](https://github.com/SXP-Simon/Panache/commit/21bf709753870258e240920495c199a27e45221e))
* **fe/src/utils:** 重复处理时保护已转写的手写表格 ([41c4579](https://github.com/SXP-Simon/Panache/commit/41c457936b2c3c38fb5a931fa16b2fe3f9eca8ef))


### Features

* **fe:** 将 Markdown 表格转换为手写方格表 ([76a2684](https://github.com/SXP-Simon/Panache/commit/76a2684e9e5390de4c9655b763a1bc9f7f7ebee3))

# [1.5.0](https://github.com/SXP-Simon/Panache/compare/v1.4.3...v1.5.0) (2026-10-18)


### Features

* **fe/src:** 支持自定义主题色并精简移动端操作区 ([73439ad](https://github.com/SXP-Simon/Panache/commit/73439ad50716f43048131b6975bb356773d140a3))

## [1.4.3](https://github.com/SXP-Simon/Panache/compare/v1.4.2...v1.4.3) (2026-10-18)


### Bug Fixes

* **be:** 保留纸张横线在文档缩图后的可见性 ([8b1c515](https://github.com/SXP-Simon/Panache/commit/8b1c515500f919a73868c8c1b982e14ee842ce58))

## [1.4.2](https://github.com/SXP-Simon/Panache/compare/v1.4.1...v1.4.2) (2026-10-17)


### Bug Fixes

* **be:** 保持横线纸数学排版的固定行网格 ([83acac5](https://github.com/SXP-Simon/Panache/commit/83acac5f85fd62dac27c66341bb6beb0b9074d6a))
* **be:** 在插图后不足完整行时换页 ([963922c](https://github.com/SXP-Simon/Panache/commit/963922c968dea2e4aad2ade62b0722c475620e48))
* **be:** 让插图后的文字回到纸张横线 ([969970d](https://github.com/SXP-Simon/Panache/commit/969970d1c25ab68f1a97a941bd79da1731edae12))
* **fe/src/utils:** 修复单字强调跨段落错误配对 ([6914687](https://github.com/SXP-Simon/Panache/commit/6914687aa6570bf1ad7ccd5a5bad446406642065))

## [1.4.1](https://github.com/SXP-Simon/Panache/compare/v1.4.0...v1.4.1) (2026-10-16)


### Bug Fixes

* **docs:** 恢复文档原有配色与链接对比度 ([f06cc88](https://github.com/SXP-Simon/Panache/commit/f06cc88f9aaecdd8327509db91ec4f479cf89cd8))
* **docs:** 更新数学公式预览图像 ([8a69f24](https://github.com/SXP-Simon/Panache/commit/8a69f245d3415e1251de02800641d839ff94d8d5))
* **e2e/desktop-tests:** 规范macOS配置目录的软链接路径 ([f2efe63](https://github.com/SXP-Simon/Panache/commit/f2efe631f0496373088bc0bf9e9aa84d127a9c16))
* **fe/src:** 清理Markdown时移除分隔线与空白行 ([fe457d1](https://github.com/SXP-Simon/Panache/commit/fe457d18cba45d7f162cf584cdb8deaac3c635d2))

# [1.4.0](https://github.com/SXP-Simon/Panache/compare/v1.3.2...v1.4.0) (2026-10-16)


### Bug Fixes

* **be/handdrawn_filter.py:** 稳定透明插图缩放与照片方向处理 ([576069a](https://github.com/SXP-Simon/Panache/commit/576069afba46aa52b5ed0cd6afc92f93e3e8a2fb))
* **fe/src/utils:** 兼容文件管理器提供的通用图片类型 ([7341591](https://github.com/SXP-Simon/Panache/commit/7341591bec9abc61cef8bd2dad67c5aa1ff84f1b))
* **fe/src:** 稳定插图解码插入与缩放引用 ([c1847f1](https://github.com/SXP-Simon/Panache/commit/c1847f1ab6a44f17e58c9813a6138498bce01f69))
* **scripts:** 固定Panache发布命名并兼容仓库更名 ([27bd6f3](https://github.com/SXP-Simon/Panache/commit/27bd6f3f51269fde05a0597c3389ffd56ce0f0c9))


### Features

* **desktop:** 更名Panache并保持原应用数据身份 ([2bb39dc](https://github.com/SXP-Simon/Panache/commit/2bb39dce1f5370037d4847765136b05e35c7eae9))
* **fe/src:** 统一Panache名称与羽毛笔品牌图标 ([6c2bd19](https://github.com/SXP-Simon/Panache/commit/6c2bd1956062e205dff34e7ad1b5ae0c4683df68))

## [1.3.2](https://github.com/SXP-Simon/handwriting-web/compare/v1.3.1...v1.3.2) (2026-10-16)


### Bug Fixes

* **ci:** build Flutter Android release APKs per ABI ([#3](https://github.com/SXP-Simon/handwriting-web/issues/3)) ([52770e3](https://github.com/SXP-Simon/handwriting-web/commit/52770e3a380e87e81f4d0a59d2dbb5110a0faec6))
* **ci:** enforce per-ABI Flutter APK outputs in release workflow ([#5](https://github.com/SXP-Simon/handwriting-web/issues/5)) ([859e135](https://github.com/SXP-Simon/handwriting-web/commit/859e135f8c98846f7f8ad3cc4b7c953c787d6078))
* **fe/src/utils:** 保持混排公式分组并清理列表缩进 ([2dbb973](https://github.com/SXP-Simon/handwriting-web/commit/2dbb973557c83c8819c8b294d3b9d2be5ae17c35))
* **fe/src/utils:** 检测闭括号之后的公式脚本 ([c69bd31](https://github.com/SXP-Simon/handwriting-web/commit/c69bd310673e7912428cf4db6b1a0ff09ac36220))
* **fe/src/utils:** 清洗时保护裸公式中的分组下标 ([1d4f661](https://github.com/SXP-Simon/handwriting-web/commit/1d4f661daefac6f3618c1ca47bafda2d7d6be7d6))
* **scripts:** 兼容固定旧源码的 Android ABI 拆包 ([e53ec13](https://github.com/SXP-Simon/handwriting-web/commit/e53ec13a58f788744f7f94a091f326b74e070cbf))
* **scripts:** 按 Android ABI 分别发布正式 APK ([ccd24d8](https://github.com/SXP-Simon/handwriting-web/commit/ccd24d82ac51bfa32447f90571e4cd10fb88f379))

## [1.3.1](https://github.com/SXP-Simon/handwriting-web/compare/v1.3.0...v1.3.1) (2026-10-15)


### Bug Fixes

* **fe/src:** 将开源仓库入口移至显眼的品牌标题区 ([79ae114](https://github.com/SXP-Simon/handwriting-web/commit/79ae1147ff158d06728e16a23ee2e1f9cfe7161d))
* **github/workflows:** 解析 Windows Flutter 构建启动器 ([c4df9de](https://github.com/SXP-Simon/handwriting-web/commit/c4df9ded200fcd0f3ddf13346abf0df929fa8c05))
* **scripts:** 保持重复更新发布说明的空白稳定 ([cb58644](https://github.com/SXP-Simon/handwriting-web/commit/cb58644122c1871e7b6a56f3f372b8dc079c8d69))
* **scripts:** 更新双客户端 Release 下载指引 ([bf02233](https://github.com/SXP-Simon/handwriting-web/commit/bf02233873cff4e5de30d72bb2ecd0d4a8c7018e))

# [1.3.0](https://github.com/SXP-Simon/handwriting-web/compare/v1.2.0...v1.3.0) (2026-10-15)


### Bug Fixes

* **scripts:** 按提交距离选择 fork 的最近发布基线 ([84ed8ca](https://github.com/SXP-Simon/handwriting-web/commit/84ed8caeff1ca145cd8b8b2f6b375b6395b3509f))


### Features

* **fe/src:** 在工作台页脚提供开源仓库入口 ([9439443](https://github.com/SXP-Simon/handwriting-web/commit/9439443546460fb2574ff26598521824259720f1))
* **scripts:** 将 Flutter 签名产物接入版本发布 ([4ea9876](https://github.com/SXP-Simon/handwriting-web/commit/4ea987648e6e0bd1ddb8e43921097e6d06dd3340))

# [1.2.0](https://github.com/SXP-Simon/handwriting-web/compare/v1.1.0...v1.2.0) (2026-10-15)


### Bug Fixes

* **be:** 移除旧站点限制并保持生成策略与部署解耦 ([ec0e662](https://github.com/SXP-Simon/handwriting-web/commit/ec0e662337b961152975069b4f7532cfd6b432ae))
* **desktop:** 从许可源目录筛选文件并验证实际发行包 ([0eb4064](https://github.com/SXP-Simon/handwriting-web/commit/0eb4064d4d4c58a79b0dfed46e680a4f7b67cb65))
* **desktop:** 使用自用发行身份并随包保留许可 ([76b228e](https://github.com/SXP-Simon/handwriting-web/commit/76b228e10ec21fb85942d94f6ac194adcb9d63ae))
* **fe/public:** 移除指向上游实例的过时站点地图 ([cb64688](https://github.com/SXP-Simon/handwriting-web/commit/cb64688a5a5093e0349f71f40b9d659d13da3a38))
* **scripts:** 累计未发布应用路径避免后续推送漏检漏发版 ([86816d5](https://github.com/SXP-Simon/handwriting-web/commit/86816d52f78da9759579714e73479df3ee0046b3))


### Features

* **api:** 统一请求契约与生成任务缓存 ([bfce708](https://github.com/SXP-Simon/handwriting-web/commit/bfce708e1459ff5dcc2d645e2a2d6628b4c075d4))
* **desktop-storage:** 封装受限存储桥与退出前保存 ([4f15c5a](https://github.com/SXP-Simon/handwriting-web/commit/4f15c5aa2078702e3c4ec1d66f83bf7abd1738e2))

# [1.1.0](https://github.com/SXP-Simon/handwriting-web/compare/v1.0.2...v1.1.0) (2026-10-15)


### Bug Fixes

* **docs:** 更新数学公式预览图像 ([e7f783f](https://github.com/SXP-Simon/handwriting-web/commit/e7f783f8b5502150967a66dfc1795244d3053a79))
* **ui:** 放大纸张与手写参数的默认值 ([ee19fb9](https://github.com/SXP-Simon/handwriting-web/commit/ee19fb95b64840953b4df8f28ca975a62b085d26))


### Features

* **ui:** 优化工作台交互与绿色视觉层次 ([6336a24](https://github.com/SXP-Simon/handwriting-web/commit/6336a24f4f85945a5c83d941229b907917c11373))

## [1.0.2](https://github.com/SXP-Simon/handwriting-web/compare/v1.0.1...v1.0.2) (2026-10-15)


### Bug Fixes

* **desktop:** 让启动与错误页也使用自托管文楷 ([1af5a60](https://github.com/SXP-Simon/handwriting-web/commit/1af5a601b0984e9ad8f8b762195a6b8a2e21c926))

## [1.0.1](https://github.com/SXP-Simon/handwriting-web/compare/v1.0.0...v1.0.1) (2026-10-15)


### Bug Fixes

* **desktop:** 避免打包时裁剪工作区构建依赖 ([f1ba704](https://github.com/SXP-Simon/handwriting-web/commit/f1ba7042ea4b98de6bcb159371f043a55c3bf552))

# 1.0.0 (2026-10-15)


### Bug Fixes

*  反馈邮件发送地址 ([e2f906d](https://github.com/SXP-Simon/handwriting-web/commit/e2f906d6e60ed88b22b33cc4d468e858af0abbd7))
* 404 not found because nginx rule ([a95d3af](https://github.com/SXP-Simon/handwriting-web/commit/a95d3afb9a559c5d23be06abc28dddbd03e25042))
* **backend:** 钉住 opencv-python<5 修复识别接口 500，并补齐三处测试空白 ([#85](https://github.com/SXP-Simon/handwriting-web/issues/85)) ([ee8075b](https://github.com/SXP-Simon/handwriting-web/commit/ee8075b62a2080e7e9164a4f34780dc00a9f44f3))
* **ci:** 固定源码 LF 行尾与图集脚本可执行权限 ([613986c](https://github.com/SXP-Simon/handwriting-web/commit/613986c846911aa824c5e91666ec106cc6c6e4fd))
* clarity不能有报错才能运行 ([75760a1](https://github.com/SXP-Simon/handwriting-web/commit/75760a13e9a8a0d13bcd02cc23d5b8e683361ba1))
* clartity需要两个脚本开启 ([fb78b2e](https://github.com/SXP-Simon/handwriting-web/commit/fb78b2ec20d7489d50384e0e7e219cfd66609b1b))
* clean LaTeX layout wrappers before Unicode conversion ([292356c](https://github.com/SXP-Simon/handwriting-web/commit/292356c61ec022372c63035c9e776d85c0845e59))
* clean up temp directory PDF files ([1a48070](https://github.com/SXP-Simon/handwriting-web/commit/1a4807081e85488a02dfad66388d2302015c1d73)), closes [#56](https://github.com/SXP-Simon/handwriting-web/issues/56)
* **dependencies:** 在 pyproject.toml 补充 fonttools 依赖并更新 uv.lock 确保字形兜底生效 ([8535d15](https://github.com/SXP-Simon/handwriting-web/commit/8535d15c64e964d5c32e3cde1d4f97d0564de723))
* **desktop:** 构建脚本里的 Python 输出强制走 UTF-8，修发版构建失败 ([#79](https://github.com/SXP-Simon/handwriting-web/issues/79)) ([739803b](https://github.com/SXP-Simon/handwriting-web/commit/739803b5cfe6bc8db862a057d64eb80134894d0e))
* **desktop:** 桌面版图标改用站点图标，并把重模块移出启动路径 ([#84](https://github.com/SXP-Simon/handwriting-web/issues/84)) ([4e05cfb](https://github.com/SXP-Simon/handwriting-web/commit/4e05cfbcb8c7400ba9c6d937f3dd3dd6c7b399e5))
* docker build fail ([bfbbb26](https://github.com/SXP-Simon/handwriting-web/commit/bfbbb26d6b5c5d45af5fbd423126c41d8f05e757))
* **engine:** 修复字体切换字形串色与字号扰动内存溢出问题 ([8e155e6](https://github.com/SXP-Simon/handwriting-web/commit/8e155e67861e345fbb1fd9e5d598dd7ef984f6ea))
* enhance PWA install prompt handling to remember user dismissal ([17a100f](https://github.com/SXP-Simon/handwriting-web/commit/17a100f9f3dac991256c75448ff996177c4a75d1))
* ensure SPA entry file is not cached for latest resource indexing ([9c7e02e](https://github.com/SXP-Simon/handwriting-web/commit/9c7e02e46cafc16ead85219233155db927309210))
* Failed to execute 'put' on 'Cache': Request method 'POST' is unsupported ([6dbbf73](https://github.com/SXP-Simon/handwriting-web/commit/6dbbf732e6f7fbfc518641a95f64432428c5ee2a))
* filename ([7ab45cc](https://github.com/SXP-Simon/handwriting-web/commit/7ab45cc6a9fd2a77c93c7e814909f9b1ab956a14))
* **font:** 完善字符集 cmap 精确检测与真实字形回退，彻底解决生僻字和下标显示为问号框的问题 ([cc74706](https://github.com/SXP-Simon/handwriting-web/commit/cc747064800048e9f3d2f6d564be3138cf05680d))
* **frontend:** 限制文本框全选范围并阻止 Ctrl+A 扩散至页面全局 ([e0004a2](https://github.com/SXP-Simon/handwriting-web/commit/e0004a27d1be2877ab50c949e39106e6c79208d7))
* install pandoc ([e6497c3](https://github.com/SXP-Simon/handwriting-web/commit/e6497c33078d39d7f16373d3a52dcc1a511a7a27))
* **latex:** 保持分母中的真分数符号原样渲染，去除多余内联斜杠 ([dd6f002](https://github.com/SXP-Simon/handwriting-web/commit/dd6f0025190f64ddedd96faf61648d8213788ec1))
* **latex:** 修复分式内部回退字形尺寸虚大与函数分母识别导致的排版错乱 ([59b8a0a](https://github.com/SXP-Simon/handwriting-web/commit/59b8a0adcba70bbfb525cd011ade33e640d9ea49))
* **latex:** 修复分母复合代数项与前缀真分数的上下竖式分式渲染 ([e7e0810](https://github.com/SXP-Simon/handwriting-web/commit/e7e0810e3c393d13df202f9bf91c8647d80f5bd9))
* **latex:** 修复复杂变量与倒数分式的上下竖式分式转换与精准边界对齐 ([0972d1c](https://github.com/SXP-Simon/handwriting-web/commit/0972d1c2dcf04b409143e6387eb51eda702b2635))
* **latex:** 全面支持自然数分数(如 1/2, 3/4)及各类分式的全自动上下竖式转换 ([3c3cc48](https://github.com/SXP-Simon/handwriting-web/commit/3c3cc48c8444159ae7d658831ab95769f02b973e))
* **latex:** 分母递归二次解析斜杠分式，消除复合公式分母遗留横排斜杠 ([29167ca](https://github.com/SXP-Simon/handwriting-web/commit/29167cae55dfd88975309fe4d1b7e54b58875088))
* **latex:** 基于深度平衡解析嵌套根号与统计均值上横线，支持复杂相关系数公式 ([6caef53](https://github.com/SXP-Simon/handwriting-web/commit/6caef535cfc76db6b659a333e4fb9d32c0d49306))
* **latex:** 扩充拉丁字母下标映射与转义下划线处理 ([7fe7198](https://github.com/SXP-Simon/handwriting-web/commit/7fe7198c47004f4d255c9baee44c35afe1bd2117))
* **latex:** 清理括号尺寸命令并保留实际括号 ([f668c65](https://github.com/SXP-Simon/handwriting-web/commit/f668c65bd7cd9020ae8d72c586c121432337974a))
* **latex:** 精确按字形 bbox 边界对齐分子和分母位置，消除分数线穿字重叠 ([6bf884a](https://github.com/SXP-Simon/handwriting-web/commit/6bf884ad33158924160e3a2d188ec0bf39391aea))
* **latex:** 补充 KaTeX 宏展开产生的 Longrightarrow 等推导长箭头映射 ([542c9ca](https://github.com/SXP-Simon/handwriting-web/commit/542c9cad68ac7ae06ca9f1c871eac2edc34f572d))
* **latex:** 递归支持分母嵌套真分数的上下竖式分式渲染，彻底清除倾斜分号 ([fcf338a](https://github.com/SXP-Simon/handwriting-web/commit/fcf338aff3450c7970e92d57b9cad6ca6a215ed8))
* **latex:** 递归支持竖式分式内部嵌套手写封顶根式渲染 ([0b3f6b7](https://github.com/SXP-Simon/handwriting-web/commit/0b3f6b77c99a3758007d42fd8ea946e3b058d4a4))
* **latex:** 采用双向深度平衡括号解析算法支持嵌套函数分式上下竖式渲染 ([2b8f95b](https://github.com/SXP-Simon/handwriting-web/commit/2b8f95b0c8bea147e46e23f4c4f3cd56d794f3c9))
* **lint:** 移除 inlineImageManager 中未使用的变量 ([4ce1403](https://github.com/SXP-Simon/handwriting-web/commit/4ce14035c29b1d4e305b40fc29d7b84ab459756a))
* **logging:** 保证 Windows 管道中的中文诊断为 UTF-8 ([ea9bf45](https://github.com/SXP-Simon/handwriting-web/commit/ea9bf4577e3d5286b77f74758c51c3bbb3b81ba7))
* **markdown:** 清洗无序列表前缀短横线并保留数学负号 ([05538a6](https://github.com/SXP-Simon/handwriting-web/commit/05538a63757e2b3efef0cf0941ab8c4a704c27cb))
* **markdown:** 清理表格条目展开中的印刷体中括号符号，改用手写自然编号与注释格式 ([43345ae](https://github.com/SXP-Simon/handwriting-web/commit/43345ae155b1e539ade193383ab42aed3d133ad3))
* **markdown:** 精准区分星号斜体与算术乘号，优化无序列表与行内格式清洗 ([ebab4e8](https://github.com/SXP-Simon/handwriting-web/commit/ebab4e8b7ef68cdd2b4228d78d86a26f623adc15))
* **math:** 强化嵌套分式根式解析并限制动态字形资源 ([8a4c62d](https://github.com/SXP-Simon/handwriting-web/commit/8a4c62d53fee6fdcf8163d88ddc81679cb727c3e))
* **math:** 按公式真实墨迹调整行距换行与分页 ([bb0ae3e](https://github.com/SXP-Simon/handwriting-web/commit/bb0ae3e9a9a57baba45f19b1b565e6b9a0194a3b))
* pdf read ([6ae7732](https://github.com/SXP-Simon/handwriting-web/commit/6ae7732f4103a9e86b6c1984f097860237f631aa))
* pdf图片大小应该为原图格式 ([e28383d](https://github.com/SXP-Simon/handwriting-web/commit/e28383d411a254fccfdfd434ed1a1aa7c440e181))
* prevent closing punctuation from starting a line ([#64](https://github.com/SXP-Simon/handwriting-web/issues/64)) ([0aaff84](https://github.com/SXP-Simon/handwriting-web/commit/0aaff84fecc6904a5d0c5acc96615e8a249cf0bd))
* prompt ([de47b42](https://github.com/SXP-Simon/handwriting-web/commit/de47b42e1d090669f7a12e17bd891e4321c2cd3d))
* **pwa:** 用内容版本替换浏览器长期缓存的旧图标 ([252c616](https://github.com/SXP-Simon/handwriting-web/commit/252c616667b91263ae1cd57f27adf8007cc98b81))
* remember full preview preference ([#65](https://github.com/SXP-Simon/handwriting-web/issues/65)) ([90b79dd](https://github.com/SXP-Simon/handwriting-web/commit/90b79dd89a69eaf2d96332a5aa06ad9dd5c495ea))
* rm zip ([ee944c8](https://github.com/SXP-Simon/handwriting-web/commit/ee944c8c207ec95a65fa198157df099c8ae9a5af))
* seo ([106dd90](https://github.com/SXP-Simon/handwriting-web/commit/106dd908fd613f6fde2a1b06271456c89174bd1e))
* seo ([8c551f0](https://github.com/SXP-Simon/handwriting-web/commit/8c551f0fb959cc95aad92f5a6c23f117f66c4263))
* sw 有网 → 用最新代码，同时写入缓存 → 离线 → 用缓存兜底 , 解决了更新后用户无法使用新页面的问题 ([5368cd4](https://github.com/SXP-Simon/handwriting-web/commit/5368cd489805cc512518da26e92ab1c9458eea50))
* tell users where the downloaded file was saved ([#97](https://github.com/SXP-Simon/handwriting-web/issues/97)) ([9e0ca9d](https://github.com/SXP-Simon/handwriting-web/commit/9e0ca9d407d124b691e4cf3f2296c13438ba3b1a))
* **test:** 按初始默认值校验跨平台字体重置 ([f5e1c39](https://github.com/SXP-Simon/handwriting-web/commit/f5e1c39eaf3f136f8c065d5c4b022afa5c45f5ff))
* **ui:** 让完整符号工具条自然换行并稳定测试定位 ([6facf63](https://github.com/SXP-Simon/handwriting-web/commit/6facf63bf623f9ef986bcaaaf8110c0e221b4111))
* update backend port mappings in docker-compose and nginx configuration ([c9864cd](https://github.com/SXP-Simon/handwriting-web/commit/c9864cd00b912324b9817b21685582cb93dabd76))
* update backend port to 5005 in app.py, docker-compose.yml, and nginx.conf ([a9bf448](https://github.com/SXP-Simon/handwriting-web/commit/a9bf4488d8e30db5b36140f229686c4e1d7ef60c))
* update exposed port from 5000 to 5005 in Dockerfile ([e07b8c7](https://github.com/SXP-Simon/handwriting-web/commit/e07b8c7a13cfdad97c577327685fdc1d54538e1a))
* update gunicorn binding port from 5000 to 5005 in Dockerfile ([c55a7c0](https://github.com/SXP-Simon/handwriting-web/commit/c55a7c029d5ebca53f264d39deae6cfe3859bee7))
* update Sentry integration to remove middleware type specification ([ad9dc1a](https://github.com/SXP-Simon/handwriting-web/commit/ad9dc1afdb1be11082b5c3a8382e9150412dbf4b))
* update Sentry integration to use ASGI middleware type ([8ab319f](https://github.com/SXP-Simon/handwriting-web/commit/8ab319f74403de08301943dcd0fcb633a433a731))
* update URLs to point to the new domain for the handwriting generation site ([e761196](https://github.com/SXP-Simon/handwriting-web/commit/e7611969ec86a0bbf86c2ec2c15ea37cb9814634))
* use run_in_threadpool for handwrite and generate_pdf to improve concurrency ([26ab988](https://github.com/SXP-Simon/handwriting-web/commit/26ab988475be0caab17182c74e92e02b378a45d9))
* version update ([80f7ad0](https://github.com/SXP-Simon/handwriting-web/commit/80f7ad0f97cd3fb2cc59b845ae24eb06a7e01a41))
* 一个日志格式化错误 ([aee6b20](https://github.com/SXP-Simon/handwriting-web/commit/aee6b206402e3795399f0c1e3b3bb9f03bfabca8))
* 下载pandoc ([90a3f31](https://github.com/SXP-Simon/handwriting-web/commit/90a3f31f869ceca74e9ab76065b320625bc502fe))
* 不支持doc文件 ([6b0864a](https://github.com/SXP-Simon/handwriting-web/commit/6b0864ad0af49e892647a542af95a243aac5de17))
* 依赖冲突 ([325a5b9](https://github.com/SXP-Simon/handwriting-web/commit/325a5b92eb6670a1839ffc3fcd4ec88cf1c6d43d))
* 依赖问题 ([84d6d8d](https://github.com/SXP-Simon/handwriting-web/commit/84d6d8d9f325ee4f4764fe2014ddbe4c2db3d41e))
* 保留混合数学文档中普通文字的负字距 ([fb01cf1](https://github.com/SXP-Simon/handwriting-web/commit/fb01cf1f7d4828d6bda4ce66ca4362b40f3c9e1b))
* 修复alpha通道问题 ([c8c6f43](https://github.com/SXP-Simon/handwriting-web/commit/c8c6f43738e61b47c37662fa5a261b74f997e4dc))
* 分开书写数学行的涂改字与正确内容 ([d257f8c](https://github.com/SXP-Simon/handwriting-web/commit/d257f8c37dad2742c8321b4b34d4bd7325a36ea2))
* 后端清理文件失败 ([7b97483](https://github.com/SXP-Simon/handwriting-web/commit/7b97483a11aa42b45a2fa8abe2c3c150ec5f7569))
* 响应式 ([caed098](https://github.com/SXP-Simon/handwriting-web/commit/caed09833a3ea65d102f01b70e04b34977116676))
* 增加超时 ([6910db4](https://github.com/SXP-Simon/handwriting-web/commit/6910db421458e502d6a3031a57646399b184573d))
* 完成任务后删除文件还有减少内存消耗 ([2bc6253](https://github.com/SXP-Simon/handwriting-web/commit/2bc6253ffe6b09d637a7103199b3bfa3391a3ee8))
* 容器目录挂载 ([7921a79](https://github.com/SXP-Simon/handwriting-web/commit/7921a793ff6fed75a1d924f956035a2e6d810bf7))
* 将字体文件直接放入后端镜像 ([4bfe2c1](https://github.com/SXP-Simon/handwriting-web/commit/4bfe2c1a068d8aa92a5fe9620635552f17be9b55))
* 延长超时时间 ([e6acd5a](https://github.com/SXP-Simon/handwriting-web/commit/e6acd5a1373bf5236e7e108f5519ce491b21f654))
* 截断 ([054003f](https://github.com/SXP-Simon/handwriting-web/commit/054003f93729dedb63f115ab5341b3e0e425ff0e))
* 按数学实际前进量计算右对齐填充 ([c8c5dbe](https://github.com/SXP-Simon/handwriting-web/commit/c8c5dbef6407c666de82178072b5dac0a92d41af))
* 文件删除冲突 ([8f7cc6a](https://github.com/SXP-Simon/handwriting-web/commit/8f7cc6a47d0c75b36fc71983771096315497bea3))
* 格式验证错误 ([96ab634](https://github.com/SXP-Simon/handwriting-web/commit/96ab634811267223303914aa7ee988e74e836bca))
* 每次生成的zip文件有不同的名字,防止互相覆盖 ([a31ac4b](https://github.com/SXP-Simon/handwriting-web/commit/a31ac4b6dc71cf68623335afebbc4abd9f7c7f86))
* 生成环境用hash ([52c650f](https://github.com/SXP-Simon/handwriting-web/commit/52c650fce13662e37b154d7d43830aa455453393))
* 类型判断错误，导致图片参数无法识别 ([1b35ce8](https://github.com/SXP-Simon/handwriting-web/commit/1b35ce8498178cae25e090dde01d88a24a15e86b))
* 重置时不清空text ([c7aac8b](https://github.com/SXP-Simon/handwriting-web/commit/c7aac8bbdd2e9097525aac480a94348c7f40c668))
* 错误显示 ([bf0080f](https://github.com/SXP-Simon/handwriting-web/commit/bf0080fdec4783e7aec8a114725b84e4503dacc5))
* 镜像过时 ([91bd115](https://github.com/SXP-Simon/handwriting-web/commit/91bd1156f151e2a934c4809fddb7790cedd203cf))
* 防止邮件重复发送，以及提示免费 ([3dad59c](https://github.com/SXP-Simon/handwriting-web/commit/3dad59cfb5697610bb26c9f256d4c4eea5f62343))


### Features

* add a persistent built-in letter preset ([#68](https://github.com/SXP-Simon/handwriting-web/issues/68)) ([af7f063](https://github.com/SXP-Simon/handwriting-web/commit/af7f063b37b43f2116e646a6a2e5e0ff6ce8f78d))
* add a Windows desktop build (Electron shell + packaged backend) ([#78](https://github.com/SXP-Simon/handwriting-web/issues/78)) ([1c01574](https://github.com/SXP-Simon/handwriting-web/commit/1c01574cab75e94cc5797591f278b6cf010379c6))
* add axios-retry for automatic request retries on network errors ([6298968](https://github.com/SXP-Simon/handwriting-web/commit/6298968593935f8a0fbdc81524893e5e18fef214))
* add BookSplash component with splash animation and user interaction ([2aebc96](https://github.com/SXP-Simon/handwriting-web/commit/2aebc966f12fe168c56207fe67dc6e88d226ed9f))
* add conditional rendering for preview header based on image availability ([fc83555](https://github.com/SXP-Simon/handwriting-web/commit/fc83555ddac9068019568d458756b55107cd6ab9))
* add custom 422 error response for improved field validation feedback ([7e073d3](https://github.com/SXP-Simon/handwriting-web/commit/7e073d31c51184890e82691effda2ccbde31c4de))
* add environment-based preview mode ([813406f](https://github.com/SXP-Simon/handwriting-web/commit/813406fbbb2bb0bffb2441b48be9f7f886936127))
* add full preview toggle for development environment in HomeView ([bc4afd4](https://github.com/SXP-Simon/handwriting-web/commit/bc4afd45ded75fd201565e97ac0e59db15aff414))
* add manual page breaks and right-aligned lines ([#66](https://github.com/SXP-Simon/handwriting-web/issues/66)) ([3bcc098](https://github.com/SXP-Simon/handwriting-web/commit/3bcc098e770efb30a7b756ce29c2192983f7e3b0))
* add multi-platform support for frontend Docker images in GitHub Actions workflow ([dadcc22](https://github.com/SXP-Simon/handwriting-web/commit/dadcc2208d605d316807e7bb64140250c58754f5))
* add one-click Chinese letter formatting ([#67](https://github.com/SXP-Simon/handwriting-web/issues/67)) ([f41b350](https://github.com/SXP-Simon/handwriting-web/commit/f41b350ca7be56c5f4595509058e3980a363c611)), closes [#0056b3](https://github.com/SXP-Simon/handwriting-web/issues/0056b3)
* add queue management for handwriting generation with active task count and user feedback and semaphore ([f93ee91](https://github.com/SXP-Simon/handwriting-web/commit/f93ee91e2f8f4d47a12debecfc4ea14be6dc45b4))
* add SW update prompt and optimize caching strategy ([6a0feab](https://github.com/SXP-Simon/handwriting-web/commit/6a0feab456d1c7e53d37b4e9925a6619b16b22ec))
* **backend:** 增加手绘墨水线稿滤镜与边缘抖动噪点仿真模块 ([845e98b](https://github.com/SXP-Simon/handwriting-web/commit/845e98bb1b1d83b5e16c3f37e9371bb58818a00d))
* **backend:** 增加根据版心实际大小与最大宽高智能等比缩放图片的自适应排版能力 ([d86c98e](https://github.com/SXP-Simon/handwriting-web/commit/d86c98e3691a96de9108d7262d4346b9c2343ddc))
* **backend:** 实现手写绘制引擎的真实字形回退与公式符号规范化 ([f5e6fa6](https://github.com/SXP-Simon/handwriting-web/commit/f5e6fa642652e551306a92e0146f3bd82efaa4ee))
* **backend:** 接入 Markdown 图文混排与手绘插图智能对齐避让渲染流 ([caea8c0](https://github.com/SXP-Simon/handwriting-web/commit/caea8c09df83cded113fa9a3d717ade3bd5a2449))
* **backend:** 支持从 Word (.docx) 中完整提取原生 OMML 数学公式与表格内容 ([79e4c73](https://github.com/SXP-Simon/handwriting-web/commit/79e4c7395518a7907b0086f41e2826d8ad370036))
* chatwoot客服 ([26f23cf](https://github.com/SXP-Simon/handwriting-web/commit/26f23cf06019a91ed894ea1d6549864f86af2bc2))
* cooldown ([04884d2](https://github.com/SXP-Simon/handwriting-web/commit/04884d2eba610d48ee6475c9c2d7fb2daf81fa24))
* CPU usage限制，字数限制 ([af9e8e1](https://github.com/SXP-Simon/handwriting-web/commit/af9e8e1d3875bbd0c39d5874000e230cf321a876))
* **desktop:** 增加 macOS 打包（arm64、未签名） ([#88](https://github.com/SXP-Simon/handwriting-web/issues/88)) ([1a85571](https://github.com/SXP-Simon/handwriting-web/commit/1a85571442797a32532b307781e5d6db8cc94b39))
* **dev:** 添加 VS Code 一键全栈启动与浏览器调试 ([ced1895](https://github.com/SXP-Simon/handwriting-web/commit/ced189545bb28ce434ffdb981c8f7ee1955b5d72))
* **fonts:** 引入开源霞鹜文楷字体并完善数学与 LaTeX 原生字形支持 ([26312f4](https://github.com/SXP-Simon/handwriting-web/commit/26312f445be2c67d87348246018cd7b7c839190f))
* **fonts:** 引入悠哉手写体、志莽行书与霞鹜漫黑三款自然随性手写字库 ([0178d64](https://github.com/SXP-Simon/handwriting-web/commit/0178d64b0681ecac1f93ac798971bd6c9a695d0c))
* **frontend:** 在文本输入框提供 LaTeX 一键转换与常用数学符号快捷插入栏 ([6e0347c](https://github.com/SXP-Simon/handwriting-web/commit/6e0347c8c7afe544c51e7be5e2395e8b7e65f76b))
* **frontend:** 增加表格清洗模式交互选择器与中英文多语言配置 ([5d91e53](https://github.com/SXP-Simon/handwriting-web/commit/5d91e537a258fe8dedc3e708b402df4d8ed6cc6a))
* **frontend:** 支持在正文编辑器中直接粘贴剪贴板图片并转为插图标记 ([b989053](https://github.com/SXP-Simon/handwriting-web/commit/b989053a6fdfeb09fc3d3494052732ae9fc82981))
* **frontend:** 新增 LaTeX 公式语法到 Unicode 手写字符的解析与转换工具 ([68e6803](https://github.com/SXP-Simon/handwriting-web/commit/68e6803ca4ed34828368eac6a11aa305c6892667))
* **frontend:** 新增 Markdown 标记一键清洗功能与纯文本转换工具 ([bb02b9e](https://github.com/SXP-Simon/handwriting-web/commit/bb02b9e961791b04680a142f2dc2c3183e311f48)), closes [#007BFF](https://github.com/SXP-Simon/handwriting-web/issues/007BFF)
* icon manifest ([d96989e](https://github.com/SXP-Simon/handwriting-web/commit/d96989e649e0a7524ae9d3d8fa3045c4486bd1c6))
* **image:** 支持插图点击大图预览与多档平滑尺寸缩放排版 ([43b9465](https://github.com/SXP-Simon/handwriting-web/commit/43b946507d61b1c68bfc2ab04af20074d1bfad9e))
* **image:** 支持插图短占位符自动折叠与Markdown清洗保护 ([2ee9250](https://github.com/SXP-Simon/handwriting-web/commit/2ee92509818e277d47f04c4924e6be0d0d651ba3))
* implement multi-page preview and update backend port to 5001 ([bc54039](https://github.com/SXP-Simon/handwriting-web/commit/bc540393298f863c6cb4e9265933528c03cddad5))
* implement SQLite task storage for cross-process task management ([f02e50b](https://github.com/SXP-Simon/handwriting-web/commit/f02e50b11177cae5de075a565d4aa04b862b138b))
* implement task management for handwriting generation with WebSocket support ([b4a8259](https://github.com/SXP-Simon/handwriting-web/commit/b4a82591ec4493becb1efa93308a22482cd8f618))
* integrate PWA support with Workbox and remove legacy service worker ([fc83a58](https://github.com/SXP-Simon/handwriting-web/commit/fc83a58261337622e558a33818e5877401381414))
* **latex:** 增强多层嵌套复杂分式递归解析与特殊转义符号转换 ([7ebe049](https://github.com/SXP-Simon/handwriting-web/commit/7ebe0497a10322f22eaa3cab99d38d6cec878a02))
* **latex:** 按公式范围转换并强化数学语义与源码保真 ([7c602aa](https://github.com/SXP-Simon/handwriting-web/commit/7c602aaf7f057d83a63bc9b84665de92332d9963))
* **latex:** 支持手写根式上方横线封顶渲染并去除多余括号 ([bc9fc80](https://github.com/SXP-Simon/handwriting-web/commit/bc9fc8059f84984f8a7aced9c3fe4410ad497cbc))
* **latex:** 支持简易矩阵与行列式环境的平铺排版转换 ([41767f2](https://github.com/SXP-Simon/handwriting-web/commit/41767f2db3b7f87e0daad533d1ebe7b1b6e17fda))
* **logging:** 统一可定位的彩色诊断与 UTF-8 轮转日志 ([927df28](https://github.com/SXP-Simon/handwriting-web/commit/927df289f5206200821240b30a86e6f9c929d7b4))
* make the three workspace columns resizable and remembered ([#91](https://github.com/SXP-Simon/handwriting-web/issues/91)) ([316e1d8](https://github.com/SXP-Simon/handwriting-web/commit/316e1d8a81683b2bbe5bd4f16a3ca93ed2dc9da7)), closes [#c8d4e3](https://github.com/SXP-Simon/handwriting-web/issues/c8d4e3) [#ddd](https://github.com/SXP-Simon/handwriting-web/issues/ddd)
* **markdown:** 支持 Markdown 表格多模式智能清洗与手写排版转换 ([1e780fd](https://github.com/SXP-Simon/handwriting-web/commit/1e780fdb38dde31db146587f5cc8ad0a86eb873d))
* **markdown:** 支持微型插图 5 至 7 倍超高比例放大 ([e9c4427](https://github.com/SXP-Simon/handwriting-web/commit/e9c4427aaf9557e2d144ac9ab2bde1b431e2dda4))
* **markdown:** 支持插图按比例放大与小图自适应扩展 ([a206c82](https://github.com/SXP-Simon/handwriting-web/commit/a206c824ab550ef7a25ef561dc19bc78f16adf99))
* **math:** 按完整基底手写绘制向量重音与下划线 ([a04a6cf](https://github.com/SXP-Simon/handwriting-web/commit/a04a6cf213257396bbfad0922366b666443b4d83))
* **math:** 支持真实手写上下双层竖式分数排版与横向分数线绘制 ([77dc6ee](https://github.com/SXP-Simon/handwriting-web/commit/77dc6ee4e35e479052026ff949873258ba595cc4))
* **math:** 用真实盒模型排版手写分式根式与上下标 ([72c14af](https://github.com/SXP-Simon/handwriting-web/commit/72c14afe19cfdb9a9305bc2e3ce95092f5535528))
* og  tc ([e3a22b9](https://github.com/SXP-Simon/handwriting-web/commit/e3a22b9aa6517c972ca2c50c884123f8ac15c994))
* pdf return ([79dea4d](https://github.com/SXP-Simon/handwriting-web/commit/79dea4dd7a97bc80854401baa3b9943af11bd49d))
* pwa ([cfe12ad](https://github.com/SXP-Simon/handwriting-web/commit/cfe12ad0215ea1eb3c33564d30c7974edb4cbb66))
* refactor GenerateHandwritingParams and add form dependency generator ([20991ad](https://github.com/SXP-Simon/handwriting-web/commit/20991ad8975f6915f6b744115b19d951cc5a09e6))
* replace alert messages with Swal toast notifications for improved user experience ([23f3427](https://github.com/SXP-Simon/handwriting-web/commit/23f34279cf0f0329ba45a2d328a9e31f0e69a7a5))
* restructure home page into a top action bar and three columns ([#77](https://github.com/SXP-Simon/handwriting-web/issues/77)) ([890eb98](https://github.com/SXP-Simon/handwriting-web/commit/890eb985c3e7a59db4cc4bd782604e394a9192ce)), closes [#textarea](https://github.com/SXP-Simon/handwriting-web/issues/textarea) [#collapseContent](https://github.com/SXP-Simon/handwriting-web/issues/collapseContent) [#0056b3](https://github.com/SXP-Simon/handwriting-web/issues/0056b3) [#003d73](https://github.com/SXP-Simon/handwriting-web/issues/003d73) [#ddd](https://github.com/SXP-Simon/handwriting-web/issues/ddd)
* seo ([1018480](https://github.com/SXP-Simon/handwriting-web/commit/1018480968dcebbb1461b2f4121473549ea26564))
* seo ([f25f7a3](https://github.com/SXP-Simon/handwriting-web/commit/f25f7a3452dc99b1e2372bb45f40fbb9bdc9643b))
* serverless feedback process backend ([c2ddd90](https://github.com/SXP-Simon/handwriting-web/commit/c2ddd9006070985352e2444004f316fef06386b9))
* sync font assets and update docker-compose configuration ([535170d](https://github.com/SXP-Simon/handwriting-web/commit/535170deb0c4c5270d4bfd7d0df2b62e29dfba68))
* text统一命名 ([0b92dc2](https://github.com/SXP-Simon/handwriting-web/commit/0b92dc25684aec61b1023716b7d67df21da5a20c))
* **ui:** 用 React 与 TypeScript 7 重建手写工作区及提交门禁 ([d9b5978](https://github.com/SXP-Simon/handwriting-web/commit/d9b5978bf4d757690cf993337c34093efbfe1950))
* **ui:** 统一霞鹜文楷并收紧工作区布局与品牌图标 ([07f8032](https://github.com/SXP-Simon/handwriting-web/commit/07f803270fe7c56444a854f521608243f07cb77d))
* 一键启动tasks.json ([bedde2b](https://github.com/SXP-Simon/handwriting-web/commit/bedde2b7e2a3fa6f19e92d06a7d604134ab415de))
* 主站最多一次十页 ([25bad47](https://github.com/SXP-Simon/handwriting-web/commit/25bad4771f53b4960c789eb40e85a5cce8a218cf))
* 取消预览文本长度限制 ([8dea082](https://github.com/SXP-Simon/handwriting-web/commit/8dea0828e9fc6b0a949c5ae942b57ab0829f7fc7))
* 增加arm平台构建 ([5012446](https://github.com/SXP-Simon/handwriting-web/commit/50124467831188cb5b116230de1347dabf17fcfe))
* 增加介绍页面 ([6412fc9](https://github.com/SXP-Simon/handwriting-web/commit/6412fc97d19ba5fedf879aac486672d9ef5275e6))
* 增加重置设置按钮 ([4137f91](https://github.com/SXP-Simon/handwriting-web/commit/4137f9136c77c3d1215637473f4eb1660ac0efdd))
* 字体大小检查 ([024eefe](https://github.com/SXP-Simon/handwriting-web/commit/024eefe241c259665be06926f0a0d08e4b61fa4d))
* 定时清理 ([eee51b7](https://github.com/SXP-Simon/handwriting-web/commit/eee51b70df64d62f25d1f1aabbeb90ac4bf4bc9d))
* 实现多页预览模式并优化环境配置 ([1d494fb](https://github.com/SXP-Simon/handwriting-web/commit/1d494fbe6c6a843d575df33a9cc2fb355be1b640))
* 对上传的图像去除第四通道 ([fea1846](https://github.com/SXP-Simon/handwriting-web/commit/fea1846ffe4ecc05c9fca0f8dc08158bab74dd58))
* 文件读取报错处理 ([8c25b53](https://github.com/SXP-Simon/handwriting-web/commit/8c25b53adec5f90b71ea5811322a08d907d1eb54))
* 读取docx文件时保留原始格式 ([90fe128](https://github.com/SXP-Simon/handwriting-web/commit/90fe128f86d5b80c5cf79b57aeca4527eb39218d))


### Performance Improvements

* **api:** 优化单页预览内存直出流与单分块快速生成 ([e55f75d](https://github.com/SXP-Simon/handwriting-web/commit/e55f75d336348943b47207eefe574d77813e37ca))
* **engine:** 引入字体CMAP与字形包围盒LRU多级缓存提升渲染吞吐 ([5eb7c30](https://github.com/SXP-Simon/handwriting-web/commit/5eb7c307af944a2a9a195868da77a366071a65ae))
* reduce first-screen load time by deferring non-critical startup work ([#63](https://github.com/SXP-Simon/handwriting-web/issues/63)) ([2cedc37](https://github.com/SXP-Simon/handwriting-web/commit/2cedc370152b240df8b955938d771f7531c3d1ac))
* shrink PDF exports by lowering the embedded JPEG quality ([#61](https://github.com/SXP-Simon/handwriting-web/issues/61)) ([45c9f9e](https://github.com/SXP-Simon/handwriting-web/commit/45c9f9e77ab3d3bc5fb1821f7754b00ca70fb833))

# [1.34.0](https://github.com/14790897/handwriting-web/compare/v1.33.1...v1.34.0) (2026-10-03)


### Features

* make the three workspace columns resizable and remembered ([#91](https://github.com/14790897/handwriting-web/issues/91)) ([316e1d8](https://github.com/14790897/handwriting-web/commit/316e1d8a81683b2bbe5bd4f16a3ca93ed2dc9da7)), closes [#c8d4e3](https://github.com/14790897/handwriting-web/issues/c8d4e3) [#9db3](https://github.com/14790897/handwriting-web/issues/9db3)

## [1.33.1](https://github.com/14790897/handwriting-web/compare/v1.33.0...v1.33.1) (2026-10-03)


### Bug Fixes

* **backend:** 钉住 opencv-python<5 修复识别接口 500，并补齐三处测试空白 ([#85](https://github.com/14790897/handwriting-web/issues/85)) ([ee8075b](https://github.com/14790897/handwriting-web/commit/ee8075b62a2080e7e9164a4f34780dc00a9f44f3))

# [1.33.0](https://github.com/14790897/handwriting-web/compare/v1.32.3...v1.33.0) (2026-10-03)


### Features

* **desktop:** 增加 macOS 打包（arm64、未签名） ([#88](https://github.com/14790897/handwriting-web/issues/88)) ([1a85571](https://github.com/14790897/handwriting-web/commit/1a85571442797a32532b307781e5d6db8cc94b39))

## [1.32.3](https://github.com/14790897/handwriting-web/compare/v1.32.2...v1.32.3) (2026-10-03)


### Bug Fixes

* **desktop:** 桌面版图标改用站点图标，并把重模块移出启动路径 ([#84](https://github.com/14790897/handwriting-web/issues/84)) ([4e05cfb](https://github.com/14790897/handwriting-web/commit/4e05cfbcb8c7400ba9c6d937f3dd3dd6c7b399e5))

## [1.32.2](https://github.com/14790897/handwriting-web/compare/v1.32.1...v1.32.2) (2026-09-29)


### Performance Improvements

* reduce first-screen load time by deferring non-critical startup work ([#63](https://github.com/14790897/handwriting-web/issues/63)) ([2cedc37](https://github.com/14790897/handwriting-web/commit/2cedc370152b240df8b955938d771f7531c3d1ac))

## [1.32.1](https://github.com/14790897/handwriting-web/compare/v1.32.0...v1.32.1) (2026-09-29)


### Bug Fixes

* **desktop:** 构建脚本里的 Python 输出强制走 UTF-8，修发版构建失败 ([#79](https://github.com/14790897/handwriting-web/issues/79)) ([739803b](https://github.com/14790897/handwriting-web/commit/739803b5cfe6bc8db862a057d64eb80134894d0e))

# [1.32.0](https://github.com/14790897/handwriting-web/compare/v1.31.0...v1.32.0) (2026-09-29)


### Features

* add a Windows desktop build (Electron shell + packaged backend) ([#78](https://github.com/14790897/handwriting-web/issues/78)) ([1c01574](https://github.com/14790897/handwriting-web/commit/1c01574cab75e94cc5797591f278b6cf010379c6))

# [1.31.0](https://github.com/14790897/handwriting-web/compare/v1.30.1...v1.31.0) (2026-09-29)


### Features

* restructure home page into a top action bar and three columns ([#77](https://github.com/14790897/handwriting-web/issues/77)) ([890eb98](https://github.com/14790897/handwriting-web/commit/890eb985c3e7a59db4cc4bd782604e394a9192ce)), closes [#0056b3](https://github.com/14790897/handwriting-web/issues/0056b3) [#003d73](https://github.com/14790897/handwriting-web/issues/003d73)

## [1.30.1](https://github.com/14790897/handwriting-web/compare/v1.30.0...v1.30.1) (2026-09-29)


### Performance Improvements

* shrink PDF exports by lowering the embedded JPEG quality ([#61](https://github.com/14790897/handwriting-web/issues/61)) ([45c9f9e](https://github.com/14790897/handwriting-web/commit/45c9f9e77ab3d3bc5fb1821f7754b00ca70fb833))

# [1.30.0](https://github.com/14790897/handwriting-web/compare/v1.29.0...v1.30.0) (2026-09-29)


### Features

* add one-click Chinese letter formatting ([#67](https://github.com/14790897/handwriting-web/issues/67)) ([f41b350](https://github.com/14790897/handwriting-web/commit/f41b350ca7be56c5f4595509058e3980a363c611)), closes [#007](https://github.com/14790897/handwriting-web/issues/007) [#0056b3](https://github.com/14790897/handwriting-web/issues/0056b3) [#003d73](https://github.com/14790897/handwriting-web/issues/003d73)

# [1.29.0](https://github.com/14790897/handwriting-web/compare/v1.28.0...v1.29.0) (2026-07-28)


### Features

* add a persistent built-in letter preset ([#68](https://github.com/14790897/handwriting-web/issues/68)) ([af7f063](https://github.com/14790897/handwriting-web/commit/af7f063b37b43f2116e646a6a2e5e0ff6ce8f78d))

# [1.28.0](https://github.com/14790897/handwriting-web/compare/v1.27.2...v1.28.0) (2026-07-28)


### Features

* add manual page breaks and right-aligned lines ([#66](https://github.com/14790897/handwriting-web/issues/66)) ([3bcc098](https://github.com/14790897/handwriting-web/commit/3bcc098e770efb30a7b756ce29c2192983f7e3b0))

## [1.27.2](https://github.com/14790897/handwriting-web/compare/v1.27.1...v1.27.2) (2026-07-27)


### Bug Fixes

* remember full preview preference ([#65](https://github.com/14790897/handwriting-web/issues/65)) ([90b79dd](https://github.com/14790897/handwriting-web/commit/90b79dd89a69eaf2d96332a5aa06ad9dd5c495ea))

## [1.27.1](https://github.com/14790897/handwriting-web/compare/v1.27.0...v1.27.1) (2026-07-27)


### Bug Fixes

* prevent closing punctuation from starting a line ([#64](https://github.com/14790897/handwriting-web/issues/64)) ([0aaff84](https://github.com/14790897/handwriting-web/commit/0aaff84fecc6904a5d0c5acc96615e8a249cf0bd))

# [1.27.0](https://github.com/14790897/handwriting-web/compare/v1.26.0...v1.27.0) (2026-05-30)


### Features

* add SW update prompt and optimize caching strategy ([6a0feab](https://github.com/14790897/handwriting-web/commit/6a0feab456d1c7e53d37b4e9925a6619b16b22ec))

# [1.26.0](https://github.com/14790897/handwriting-web/compare/v1.25.2...v1.26.0) (2026-04-25)


### Features

* integrate PWA support with Workbox and remove legacy service worker ([fc83a58](https://github.com/14790897/handwriting-web/commit/fc83a58261337622e558a33818e5877401381414))

## [1.25.2](https://github.com/14790897/handwriting-web/compare/v1.25.1...v1.25.2) (2026-04-24)


### Bug Fixes

* update URLs to point to the new domain for the handwriting generation site ([e761196](https://github.com/14790897/handwriting-web/commit/e7611969ec86a0bbf86c2ec2c15ea37cb9814634))

## [1.25.1](https://github.com/14790897/handwriting-web/compare/v1.25.0...v1.25.1) (2026-04-22)


### Bug Fixes

* ensure SPA entry file is not cached for latest resource indexing ([9c7e02e](https://github.com/14790897/handwriting-web/commit/9c7e02e46cafc16ead85219233155db927309210))

# [1.25.0](https://github.com/14790897/handwriting-web/compare/v1.24.0...v1.25.0) (2026-04-22)


### Features

* add axios-retry for automatic request retries on network errors ([6298968](https://github.com/14790897/handwriting-web/commit/6298968593935f8a0fbdc81524893e5e18fef214))

# [1.24.0](https://github.com/14790897/handwriting-web/compare/v1.23.0...v1.24.0) (2026-04-21)


### Features

* add conditional rendering for preview header based on image availability ([fc83555](https://github.com/14790897/handwriting-web/commit/fc83555ddac9068019568d458756b55107cd6ab9))

# [1.23.0](https://github.com/14790897/handwriting-web/compare/v1.22.0...v1.23.0) (2026-04-21)


### Features

* replace alert messages with Swal toast notifications for improved user experience ([23f3427](https://github.com/14790897/handwriting-web/commit/23f34279cf0f0329ba45a2d328a9e31f0e69a7a5))

# [1.22.0](https://github.com/14790897/handwriting-web/compare/v1.21.1...v1.22.0) (2026-04-21)


### Features

* add BookSplash component with splash animation and user interaction ([2aebc96](https://github.com/14790897/handwriting-web/commit/2aebc966f12fe168c56207fe67dc6e88d226ed9f))

## [1.21.1](https://github.com/14790897/handwriting-web/compare/v1.21.0...v1.21.1) (2026-04-18)


### Bug Fixes

* 类型判断错误，导致图片参数无法识别 ([1b35ce8](https://github.com/14790897/handwriting-web/commit/1b35ce8498178cae25e090dde01d88a24a15e86b))

# [1.21.0](https://github.com/14790897/handwriting-web/compare/v1.20.4...v1.21.0) (2026-04-18)


### Features

* add custom 422 error response for improved field validation feedback ([7e073d3](https://github.com/14790897/handwriting-web/commit/7e073d31c51184890e82691effda2ccbde31c4de))

## [1.20.4](https://github.com/14790897/handwriting-web/compare/v1.20.3...v1.20.4) (2026-04-18)


### Bug Fixes

* sw 有网 → 用最新代码，同时写入缓存 → 离线 → 用缓存兜底 , 解决了更新后用户无法使用新页面的问题 ([5368cd4](https://github.com/14790897/handwriting-web/commit/5368cd489805cc512518da26e92ab1c9458eea50))

## [1.20.3](https://github.com/14790897/handwriting-web/compare/v1.20.2...v1.20.3) (2026-04-17)


### Bug Fixes

* enhance PWA install prompt handling to remember user dismissal ([17a100f](https://github.com/14790897/handwriting-web/commit/17a100f9f3dac991256c75448ff996177c4a75d1))

## [1.20.2](https://github.com/14790897/handwriting-web/compare/v1.20.1...v1.20.2) (2026-04-17)


### Bug Fixes

* update Sentry integration to remove middleware type specification ([ad9dc1a](https://github.com/14790897/handwriting-web/commit/ad9dc1afdb1be11082b5c3a8382e9150412dbf4b))

## [1.20.1](https://github.com/14790897/handwriting-web/compare/v1.20.0...v1.20.1) (2026-04-17)


### Bug Fixes

* update Sentry integration to use ASGI middleware type ([8ab319f](https://github.com/14790897/handwriting-web/commit/8ab319f74403de08301943dcd0fcb633a433a731))

# [1.20.0](https://github.com/14790897/handwriting-web/compare/v1.19.0...v1.20.0) (2026-04-17)


### Features

* refactor GenerateHandwritingParams and add form dependency generator ([20991ad](https://github.com/14790897/handwriting-web/commit/20991ad8975f6915f6b744115b19d951cc5a09e6))

# [1.19.0](https://github.com/14790897/handwriting-web/compare/v1.18.4...v1.19.0) (2026-04-17)


### Bug Fixes

* use run_in_threadpool for handwrite and generate_pdf to improve concurrency ([26ab988](https://github.com/14790897/handwriting-web/commit/26ab988475be0caab17182c74e92e02b378a45d9))
* 格式验证错误 ([96ab634](https://github.com/14790897/handwriting-web/commit/96ab634811267223303914aa7ee988e74e836bca))


### Features

* add queue management for handwriting generation with active task count and user feedback and semaphore ([f93ee91](https://github.com/14790897/handwriting-web/commit/f93ee91e2f8f4d47a12debecfc4ea14be6dc45b4))
* implement SQLite task storage for cross-process task management ([f02e50b](https://github.com/14790897/handwriting-web/commit/f02e50b11177cae5de075a565d4aa04b862b138b))
* implement task management for handwriting generation with WebSocket support ([b4a8259](https://github.com/14790897/handwriting-web/commit/b4a82591ec4493becb1efa93308a22482cd8f618))

## [1.18.4](https://github.com/14790897/handwriting-web/compare/v1.18.3...v1.18.4) (2026-03-11)


### Bug Fixes

* Failed to execute 'put' on 'Cache': Request method 'POST' is unsupported ([6dbbf73](https://github.com/14790897/handwriting-web/commit/6dbbf732e6f7fbfc518641a95f64432428c5ee2a))

## [1.18.3](https://github.com/14790897/handwriting-web/compare/v1.18.2...v1.18.3) (2026-02-09)


### Bug Fixes

* clean up temp directory PDF files ([1a48070](https://github.com/14790897/handwriting-web/commit/1a4807081e85488a02dfad66388d2302015c1d73)), closes [#56](https://github.com/14790897/handwriting-web/issues/56)

## [1.18.2](https://github.com/14790897/handwriting-web/compare/v1.18.1...v1.18.2) (2025-12-26)


### Bug Fixes

* update exposed port from 5000 to 5005 in Dockerfile ([e07b8c7](https://github.com/14790897/handwriting-web/commit/e07b8c7a13cfdad97c577327685fdc1d54538e1a))

## [1.18.1](https://github.com/14790897/handwriting-web/compare/v1.18.0...v1.18.1) (2025-12-26)


### Bug Fixes

* update gunicorn binding port from 5000 to 5005 in Dockerfile ([c55a7c0](https://github.com/14790897/handwriting-web/commit/c55a7c029d5ebca53f264d39deae6cfe3859bee7))

# [1.18.0](https://github.com/14790897/handwriting-web/compare/v1.17.1...v1.18.0) (2025-12-26)


### Features

* add multi-platform support for frontend Docker images in GitHub Actions workflow ([dadcc22](https://github.com/14790897/handwriting-web/commit/dadcc2208d605d316807e7bb64140250c58754f5))

## [1.17.1](https://github.com/14790897/handwriting-web/compare/v1.17.0...v1.17.1) (2025-12-26)


### Bug Fixes

* update backend port to 5005 in app.py, docker-compose.yml, and nginx.conf ([a9bf448](https://github.com/14790897/handwriting-web/commit/a9bf4488d8e30db5b36140f229686c4e1d7ef60c))

# [1.17.0](https://github.com/14790897/handwriting-web/compare/v1.16.0...v1.17.0) (2025-12-26)


### Features

* sync font assets and update docker-compose configuration ([535170d](https://github.com/14790897/handwriting-web/commit/535170deb0c4c5270d4bfd7d0df2b62e29dfba68))

# [1.16.0](https://github.com/14790897/handwriting-web/compare/v1.15.2...v1.16.0) (2025-12-26)


### Features

* chatwoot客服 ([26f23cf](https://github.com/14790897/handwriting-web/commit/26f23cf06019a91ed894ea1d6549864f86af2bc2))

## [1.15.2](https://github.com/14790897/handwriting-web/compare/v1.15.1...v1.15.2) (2025-12-26)


### Bug Fixes

* 将字体文件直接放入后端镜像 ([4bfe2c1](https://github.com/14790897/handwriting-web/commit/4bfe2c1a068d8aa92a5fe9620635552f17be9b55))

## [1.15.1](https://github.com/14790897/handwriting-web/compare/v1.15.0...v1.15.1) (2025-12-26)


### Bug Fixes

* update backend port mappings in docker-compose and nginx configuration ([c9864cd](https://github.com/14790897/handwriting-web/commit/c9864cd00b912324b9817b21685582cb93dabd76))

# [1.15.0](https://github.com/14790897/handwriting-web/compare/v1.14.0...v1.15.0) (2025-12-26)


### Features

* add full preview toggle for development environment in HomeView ([bc4afd4](https://github.com/14790897/handwriting-web/commit/bc4afd45ded75fd201565e97ac0e59db15aff414))

# [1.14.0](https://github.com/14790897/handwriting-web/compare/v1.13.4...v1.14.0) (2025-12-26)


### Features

* add environment-based preview mode ([813406f](https://github.com/14790897/handwriting-web/commit/813406fbbb2bb0bffb2441b48be9f7f886936127))
* implement multi-page preview and update backend port to 5001 ([bc54039](https://github.com/14790897/handwriting-web/commit/bc540393298f863c6cb4e9265933528c03cddad5))
* 实现多页预览模式并优化环境配置 ([1d494fb](https://github.com/14790897/handwriting-web/commit/1d494fbe6c6a843d575df33a9cc2fb355be1b640))

## [1.13.4](https://github.com/14790897/handwriting-web/compare/v1.13.3...v1.13.4) (2025-12-09)


### Bug Fixes

* 下载pandoc ([90a3f31](https://github.com/14790897/handwriting-web/commit/90a3f31f869ceca74e9ab76065b320625bc502fe))

## [1.13.3](https://github.com/14790897/handwriting-web/compare/v1.13.2...v1.13.3) (2025-12-09)


### Bug Fixes

* install pandoc ([e6497c3](https://github.com/14790897/handwriting-web/commit/e6497c33078d39d7f16373d3a52dcc1a511a7a27))

## [1.13.2](https://github.com/14790897/handwriting-web/compare/v1.13.1...v1.13.2) (2025-12-05)


### Bug Fixes

* 镜像过时 ([91bd115](https://github.com/14790897/handwriting-web/commit/91bd1156f151e2a934c4809fddb7790cedd203cf))

## [1.13.1](https://github.com/14790897/handwriting-web/compare/v1.13.0...v1.13.1) (2025-09-18)


### Bug Fixes

* seo ([106dd90](https://github.com/14790897/handwriting-web/commit/106dd908fd613f6fde2a1b06271456c89174bd1e))

# [1.13.0](https://github.com/14790897/handwriting-web/compare/v1.12.0...v1.13.0) (2025-07-12)


### Features

* text统一命名 ([0b92dc2](https://github.com/14790897/handwriting-web/commit/0b92dc25684aec61b1023716b7d67df21da5a20c))

# [1.12.0](https://github.com/14790897/handwriting-web/compare/v1.11.1...v1.12.0) (2025-07-12)


### Features

* 一键启动tasks.json ([bedde2b](https://github.com/14790897/handwriting-web/commit/bedde2b7e2a3fa6f19e92d06a7d604134ab415de))

## [1.11.1](https://github.com/14790897/handwriting-web/compare/v1.11.0...v1.11.1) (2025-07-08)


### Bug Fixes

* 响应式 ([caed098](https://github.com/14790897/handwriting-web/commit/caed09833a3ea65d102f01b70e04b34977116676))

# [1.11.0](https://github.com/14790897/handwriting-web/compare/v1.10.3...v1.11.0) (2025-07-08)


### Features

* cooldown ([04884d2](https://github.com/14790897/handwriting-web/commit/04884d2eba610d48ee6475c9c2d7fb2daf81fa24))

## [1.10.3](https://github.com/14790897/handwriting-web/compare/v1.10.2...v1.10.3) (2025-07-08)


### Bug Fixes

* rm zip ([ee944c8](https://github.com/14790897/handwriting-web/commit/ee944c8c207ec95a65fa198157df099c8ae9a5af))

## [1.10.2](https://github.com/14790897/handwriting-web/compare/v1.10.1...v1.10.2) (2025-07-08)


### Bug Fixes

* 截断 ([054003f](https://github.com/14790897/handwriting-web/commit/054003f93729dedb63f115ab5341b3e0e425ff0e))

## [1.10.1](https://github.com/14790897/handwriting-web/compare/v1.10.0...v1.10.1) (2025-07-08)


### Bug Fixes

* 后端清理文件失败 ([7b97483](https://github.com/14790897/handwriting-web/commit/7b97483a11aa42b45a2fa8abe2c3c150ec5f7569))

# [1.10.0](https://github.com/14790897/handwriting-web/compare/v1.9.0...v1.10.0) (2025-07-08)


### Features

* 主站最多一次十页 ([25bad47](https://github.com/14790897/handwriting-web/commit/25bad4771f53b4960c789eb40e85a5cce8a218cf))

# [1.9.0](https://github.com/14790897/handwriting-web/compare/v1.8.0...v1.9.0) (2025-07-08)


### Features

* pwa ([cfe12ad](https://github.com/14790897/handwriting-web/commit/cfe12ad0215ea1eb3c33564d30c7974edb4cbb66))

# [1.8.0](https://github.com/14790897/handwriting-web/compare/v1.7.2...v1.8.0) (2025-07-08)


### Features

* icon manifest ([d96989e](https://github.com/14790897/handwriting-web/commit/d96989e649e0a7524ae9d3d8fa3045c4486bd1c6))

## [1.7.2](https://github.com/14790897/handwriting-web/compare/v1.7.1...v1.7.2) (2025-07-07)


### Bug Fixes

* 容器目录挂载 ([7921a79](https://github.com/14790897/handwriting-web/commit/7921a793ff6fed75a1d924f956035a2e6d810bf7))

## [1.7.1](https://github.com/14790897/handwriting-web/compare/v1.7.0...v1.7.1) (2025-07-07)


### Bug Fixes

* 404 not found because nginx rule ([a95d3af](https://github.com/14790897/handwriting-web/commit/a95d3afb9a559c5d23be06abc28dddbd03e25042))

# [1.7.0](https://github.com/14790897/handwriting-web/compare/v1.6.0...v1.7.0) (2025-06-19)


### Features

* seo ([1018480](https://github.com/14790897/handwriting-web/commit/1018480968dcebbb1461b2f4121473549ea26564))

# [1.6.0](https://github.com/14790897/handwriting-web/compare/v1.5.3...v1.6.0) (2025-05-27)


### Features

* 增加arm平台构建 ([5012446](https://github.com/14790897/handwriting-web/commit/50124467831188cb5b116230de1347dabf17fcfe))

## [1.5.3](https://github.com/14790897/handwriting-web/compare/v1.5.2...v1.5.3) (2025-05-27)


### Bug Fixes

* pdf图片大小应该为原图格式 ([e28383d](https://github.com/14790897/handwriting-web/commit/e28383d411a254fccfdfd434ed1a1aa7c440e181))

## [1.5.2](https://github.com/14790897/handwriting-web/compare/v1.5.1...v1.5.2) (2025-02-19)


### Bug Fixes

* 防止邮件重复发送，以及提示免费 ([3dad59c](https://github.com/14790897/handwriting-web/commit/3dad59cfb5697610bb26c9f256d4c4eea5f62343))

## [1.5.1](https://github.com/14790897/handwriting-web/compare/v1.5.0...v1.5.1) (2025-02-15)


### Bug Fixes

* 重置时不清空text ([c7aac8b](https://github.com/14790897/handwriting-web/commit/c7aac8bbdd2e9097525aac480a94348c7f40c668))

# [1.5.0](https://github.com/14790897/handwriting-web/compare/v1.4.0...v1.5.0) (2025-02-14)


### Bug Fixes

*  反馈邮件发送地址 ([e2f906d](https://github.com/14790897/handwriting-web/commit/e2f906d6e60ed88b22b33cc4d468e858af0abbd7))
* clarity不能有报错才能运行 ([75760a1](https://github.com/14790897/handwriting-web/commit/75760a13e9a8a0d13bcd02cc23d5b8e683361ba1))
* clartity需要两个脚本开启 ([fb78b2e](https://github.com/14790897/handwriting-web/commit/fb78b2ec20d7489d50384e0e7e219cfd66609b1b))
* seo ([8c551f0](https://github.com/14790897/handwriting-web/commit/8c551f0fb959cc95aad92f5a6c23f117f66c4263))
* version update ([80f7ad0](https://github.com/14790897/handwriting-web/commit/80f7ad0f97cd3fb2cc59b845ae24eb06a7e01a41))
* 一个日志格式化错误 ([aee6b20](https://github.com/14790897/handwriting-web/commit/aee6b206402e3795399f0c1e3b3bb9f03bfabca8))
* 不支持doc文件 ([6b0864a](https://github.com/14790897/handwriting-web/commit/6b0864ad0af49e892647a542af95a243aac5de17))
* 依赖冲突 ([325a5b9](https://github.com/14790897/handwriting-web/commit/325a5b92eb6670a1839ffc3fcd4ec88cf1c6d43d))
* 依赖问题 ([84d6d8d](https://github.com/14790897/handwriting-web/commit/84d6d8d9f325ee4f4764fe2014ddbe4c2db3d41e))
* 修复alpha通道问题 ([c8c6f43](https://github.com/14790897/handwriting-web/commit/c8c6f43738e61b47c37662fa5a261b74f997e4dc))
* 完成任务后删除文件还有减少内存消耗 ([2bc6253](https://github.com/14790897/handwriting-web/commit/2bc6253ffe6b09d637a7103199b3bfa3391a3ee8))
* 延长超时时间 ([e6acd5a](https://github.com/14790897/handwriting-web/commit/e6acd5a1373bf5236e7e108f5519ce491b21f654))
* 文件删除冲突 ([8f7cc6a](https://github.com/14790897/handwriting-web/commit/8f7cc6a47d0c75b36fc71983771096315497bea3))
* 生成环境用hash ([52c650f](https://github.com/14790897/handwriting-web/commit/52c650fce13662e37b154d7d43830aa455453393))
* 错误显示 ([bf0080f](https://github.com/14790897/handwriting-web/commit/bf0080fdec4783e7aec8a114725b84e4503dacc5))


### Features

* CPU usage限制，字数限制 ([af9e8e1](https://github.com/14790897/handwriting-web/commit/af9e8e1d3875bbd0c39d5874000e230cf321a876))
* og  tc ([e3a22b9](https://github.com/14790897/handwriting-web/commit/e3a22b9aa6517c972ca2c50c884123f8ac15c994))
* seo ([f25f7a3](https://github.com/14790897/handwriting-web/commit/f25f7a3452dc99b1e2372bb45f40fbb9bdc9643b))
* 取消预览文本长度限制 ([8dea082](https://github.com/14790897/handwriting-web/commit/8dea0828e9fc6b0a949c5ae942b57ab0829f7fc7))
* 增加介绍页面 ([6412fc9](https://github.com/14790897/handwriting-web/commit/6412fc97d19ba5fedf879aac486672d9ef5275e6))
* 增加重置设置按钮 ([4137f91](https://github.com/14790897/handwriting-web/commit/4137f9136c77c3d1215637473f4eb1660ac0efdd))
* 字体大小检查 ([024eefe](https://github.com/14790897/handwriting-web/commit/024eefe241c259665be06926f0a0d08e4b61fa4d))
* 对上传的图像去除第四通道 ([fea1846](https://github.com/14790897/handwriting-web/commit/fea1846ffe4ecc05c9fca0f8dc08158bab74dd58))
* 文件读取报错处理 ([8c25b53](https://github.com/14790897/handwriting-web/commit/8c25b53adec5f90b71ea5811322a08d907d1eb54))
* 读取docx文件时保留原始格式 ([90fe128](https://github.com/14790897/handwriting-web/commit/90fe128f86d5b80c5cf79b57aeca4527eb39218d))
