# CheatSheet Modern

面向 macOS 14 及以上版本的原生菜单栏快捷键工具。切换到任意应用，**单独长按 ⌘**，查看该应用菜单中公开的快捷键，松开后关闭。

这是独立实现，不是 Media Atelier 的官方更新，也不包含原版源码、图标或其他资源。原版安装包的只读分析见 [docs/original-app-analysis.md](docs/original-app-analysis.md)。

## 开发环境

- macOS 14+，Apple silicon 或 Intel。
- Swift 6.0+；Xcode Command Line Tools 足以构建应用和运行核心检查。
- 完整 Xcode 用于 `swift test` / XCTest；仅安装 Command Line Tools 时不包含 XCTest。
- 无第三方依赖，无额外包管理器。`Package.swift` 是工具链和部署版本的唯一声明。

```sh
# 查看当前选择的工具链
xcode-select -p
swift --version

# 编译并运行不需要额外权限的核心检查
bash scripts/check.sh

# 离屏布局、横向滚动和读取会话检查，无需辅助功能或录屏权限
bash scripts/check-ui.sh

# 完整 Xcode 环境下，额外运行 XCTest
bash scripts/check.sh --xctest

# 构建当前机器架构的 release 应用
bash scripts/build-app.sh

# 或构建 Apple silicon + Intel 通用应用
bash scripts/build-app.sh --universal
```

产物为 `dist/CheatSheet Modern.app`。脚本只替换这个生成目录，不会覆盖 `/Applications/CheatSheet.app`，也不会自动启动或授权应用。可以用 Xcode 打开 `Package.swift`，或直接使用支持 Swift Package Manager 的编辑器。

**请运行打包后的 `.app`，不要把 `swift run` 作为日常使用方式。** 本地化、应用身份、辅助功能授权和登录项都需要完整应用包。

## 安装与使用

1. 将 `dist/CheatSheet Modern.app` 复制到 `/Applications`；先确定好固定位置，再授权。
2. 打开应用，在设置中点击“允许辅助功能访问”。
3. 在“系统设置 → 隐私与安全性 → 辅助功能”中启用 **CheatSheet Modern**。如果没有列出，使用 `+` 添加应用。
4. 切换到 Finder、Safari、TextEdit 等应用，单独长按 ⌘，默认等待 1 秒。
5. 普通模式下松开 ⌘ 关闭面板。点击面板左下角的 **⌘ 按钮**可固定窗口，之后松开按键仍保持置顶，便于截图；点击窗口外关闭并恢复普通模式。再次点击 ⌘ 可取消固定。
6. 固定后可使用系统截图快捷键；窗口截图可按 `⌘⇧4`、空格，再点击面板。普通窗口外点击仍会关闭面板，因此拖框截图若从面板外开始，可能触发关闭。
7. 使用菜单栏中的 ⌘ 图标暂停、调整等待时间或退出。

面板按原版已核验的布局度量重建：无顶部标题区，四列之间用竖线分隔；快捷键在左、名称在右，分组标题与名称对齐。原生 13pt 字体、22pt 行高、左右 16pt 留白、20pt 列间距、74＋4pt 快捷键槽及 48pt 底栏。内容自上而下填充再向右续列，分组独立堆叠；跨列分组在每个续列顶部重复原组标题，并预留相同的标题空间。保留横向滚动，不压缩快捷键字形。

底栏左侧增加 ⌘ 固定按钮，右下角说明文字已隐藏，右侧设置按钮保留；使用独立名称，不冒用原作者署名或复用原图片。已确认的参数、原版参考渲染方法以及尚未逐像素对齐的部分见 [docs/layout-reference.md](docs/layout-reference.md)；目前不能宣称与原版实际运行截图完全一致。

设置提供 0.4–2 秒的等待时间和通过 `SMAppService` 注册的登录时启动。登录项需要从固定安装位置运行，系统可能要求用户额外批准。

### 本地签名与发布

默认使用 ad-hoc 签名，仅用于本机构建。它**不是 Developer ID 签名，也没有完成公证**；不能据此宣称可直接分发给其他用户。ad-hoc 重建后身份可能变化，系统可能要求在辅助功能列表中移除旧条目、重新添加并重启应用。项目不自动移除隔离标记或修改系统安全设置。

有自己的 Developer ID 时，可指定签名身份：

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/build-app.sh --universal
```

该模式启用 hardened runtime 和签名时间戳。对外发布前仍需使用自己的 Apple 开发者凭据完成公证、staple，并验证 Gatekeeper 接受结果。应用身份为 `local.cheatsheet.modern`，不冒用原版的 `com.mediaatelier.CheatSheet`；正式发布前应改成自己控制的标识，并在首次分发前固定下来。

## 结构

```text
Package.swift
Sources/
  CheatSheetCore/       快捷键数据、菜单读取、确定性的长按状态机
  CheatSheetApp/        应用生命周期、事件监听、菜单栏、原生面板和设置
Resources/
  Info.plist           独立应用身份，LSUIElement，无 Dock 常驻图标
  en.lproj/            英文界面
  zh-Hans.lproj/       简体中文界面
Tests/
  CheatSheetCoreTests/  XCTest：状态机、菜单遍历、快捷键格式、取消与上限
scripts/
  build-app.sh         构建、打包、生成独立图标、签名及签名检查
  check.sh             编译 + 核心及 AX 属性请求检查；可选 XCTest
  check-ui.sh          读取会话、分栏、横向滚动及离屏渲染检查
  core-check.swift     无 XCTest 依赖的核心回归检查
  make-icon.swift      生成原创应用图标
```

架构与手工验收清单见 [docs/architecture.md](docs/architecture.md)。

## 隐私与限制

- 单独按住 ⌘ 80ms 后，在长按等待期间读取前台应用的 Accessibility 菜单属性。松键会关闭普通面板，但已经开始的有界读取可以完成，供同一上下文的下一次查看复用；正常输入、外部点击/滚动、切换应用或权限变化会使结果失效。
- 仅在内存中保留一份最多 3 秒的可用快照，每次展示仍后台重新验证；不持久化菜单，不读取键盘事件中的字符内容、不发送网络请求、无遥测。程序自动改变焦点/菜单状态时仍可能短暂看到刷新前的内容，不宣称快照始终实时。
- 首批快捷键可读后即逐步显示，不等待整棵菜单树；个别子项消失或暂时无法读取时保留其他结果。根菜单短暂不可读时最多重试一次，权限和应用失效不重试。
- 监听仅用于判断修饰键状态和取消手势；本地事件原样返回，不拦截正常快捷键。
- 读取在后台执行，设置单次 AX 消息超时、总体时间、节点和深度上限；结果可能不完整。
- 仅展示应用通过菜单公开的快捷键。动态菜单、部分跨平台界面和安全输入场景可能不可读。
- 禁用命令以灰色展示。列表是触发时的快照，不代表点击即可执行，也不是所有快捷键的完整数据库。
- 当前没有搜索、快捷键自定义、自动更新或云同步。

## 当前验证范围

核心检查不需要辅助功能权限；覆盖真实状态机、固定/取消固定及下一次触发、键名格式化、菜单树局部恢复和 AX 批处理。读取会话检查覆盖短期复用、上下文/TTL 隔离、渐进结果、瞬时失败重试、取消与迟到结果；离屏渲染检查覆盖分栏、横向滚动和真实原生按钮回调。它们不等价于端到端验证：实际授权、跨应用事件交付、输入框聚焦时的读取延迟、真实鼠标固定/外部点击、系统截图、全屏 Spaces 和登录时启动仍需在打包应用上验收。

`bash scripts/check-ui.sh` 会生成 `.build/overlay-preview.png`、深色及小窗口预览。这些使用实际界面代码和测试菜单，不会截取桌面，也不会启动已安装应用。

需要排查具体应用读取慢时，可以先在终端执行以下命令，再切换到该应用聚焦输入框并长按 ⌘；完成后按 Control-C 结束。日志只包含固定的成功/重试/失败分类、读取耗时和快捷键数量，不含菜单标题、应用名称或输入文字。最终失败会记录权限、应用失效或菜单不可读分类；它不能替代实际应用场景的复现：

```sh
log stream --level debug --style compact --predicate 'subsystem == "local.cheatsheet.modern" AND category == "MenuReading"'
```

本项目不会自动为用户授予权限或替换正在运行的已安装应用。

项目尚未指定开源许可证。发布前需由项目所有者决定授权条款；原版产品的权利不因本项目分析而改变。
