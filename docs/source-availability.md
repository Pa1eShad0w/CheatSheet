# 原版 CheatSheet：源码调查与忠实复刻目标

研究日期：2026-10-27。对象仅为 Media Atelier / Stefan Fuerst 的 macOS CheatSheet（`com.mediaatelier.CheatSheet`），不是其他同名项目。

## 结论

**目前没有找到可核验为原版、带可确认复用许可的公开源码仓库。** 后续成功完成的 GitHub 查询与官网检查，补齐了初轮网络失败造成的部分证据缺口；但这仍不能证明源码从未公开，或不可能存在于未被检索到的其他位置。

工程上应按“没有可用的原版源码”处理，而不是把 Homebrew 安装配方、二进制镜像或第三方同名工程当成原版开发仓库。

用户提出的目标是：如果没有原版源码，接受的方向是忠实复现原版体验，而非仅实现类似功能的重新设计。**现代化应主要发生在实现、兼容性、权限和分发层；不能借此擅自改变原版的可观察交互和布局。** 当前代码只是可编译的技术基础，尚未达到逐点复刻验收。

## 已取得的一手证据

### 1. 原版发行包身份

本地只读分析已核验 1.6.4 DMG 的 SHA-256 与 [Homebrew API][1] 完全一致；应用为 `com.mediaatelier.CheatSheet`，签名者 Stefan Fuerst（`2295B9BX7F`）。详情见 [原版安装包分析][2]。

Homebrew 提供的是二进制下载地址，并将其标记为 `discontinued`。API 中的 `ruby_source_path` 是 Homebrew 的 Ruby 安装配方，不是应用源码。这些信息不构成作者关于源码许可或闭源状态的声明。

### 2. 官网旧入口当前不再展示 CheatSheet

实际请求 [原版主页][3]，最终地址为：

```text
https://www.mediaatelier.com/de-DE/GrandTotal/
```

返回 GrandTotal 页面，没有从这一入口获得 CheatSheet 源码链接。该结果只说明当前入口的状态，不证明历史页面从未链接源码。

### 3. `mediaatelier` GitHub 账号

[账号资料][4] 的 `blog` 指向 `https://mediaatelier.com`，`public_repos` 为 2。[公开仓库列表][5] 实际返回：

- `mediaatelier/GrandTotal-Plugins`
- `mediaatelier/Umsatzsteuer-Voranmeldung.grandtotalplugin`

列表中没有 CheatSheet。账号自述关联官网是线索；本次未取得官网反向链接，因此不单凭用户名将其视为经过独立认证的作者全部代码清单。私有、删除、迁移或其他账号下的仓库不在这一结果范围内。

### 4. GitHub 仓库搜索

以下查询成功返回，均为仓库搜索，不是需要登录授权的全站源码搜索：

| 查询 | 返回结果 | 可得结论 |
| --- | --- | --- |
| [CheatSheet + mediaatelier][6] | `total_count: 0` | 默认仓库检索范围中未命中；不是全站不存在证明 |
| [CheatSheet + 精确短语 Media Atelier，搜索 README][7] | `total_count: 0` | 未获得候选原版仓库 |
| [CheatSheet + Stefan Fuerst，搜索 README][8] | `total_count: 0` | 未获得候选原版仓库 |
| [原版 bundle identifier，搜索 README][9] | 1 个：`REDNBLACK/preferences` | 返回的是描述为 Shell/program settings 的配置仓库；不是已确认的原版工程 |
| [CheatSheet + mediaatelier.com，搜索 README][10] | 12 个 | 返回的软件清单、配置等条目未提供能确认的原版源码候选；没有逐个完整审计，不能将全部条目作绝对排除 |

另按 Objective-C / Swift 查询同名仓库，并检查部分候选的根目录和 README：

- [danielsimons1/cheatsheet][11]：根目录含 `NoteCard`，README 仅有标题，无原作者归属或许可证据，不能认定为原版。
- [TakanoriHasebe/CheatSheet][12]：README 与目录为 Swift/界面示例资料，没有原版来源证据。
- [martongreber/CheatSheet][13]：README 明确说明是 `cheat.sh` 的 Xcode 客户端，不是 Media Atelier 的工具。

没有取得作者明确宣布“CheatSheet 已开源”或“源码不公开”的原文。公开可见的第三方重写，即使功能相同，也不能当成原版源码。

## 没有源码与逐点复刻的关系

源码不可得并不在技术上强制要求逐点复刻，但**忠实复刻可以是用户明确选择的产品要求**，本项目应尊重这一要求。此前“源码不存在也可以做任意独立设计”的工程建议，不能替代产品验收标准。

应分清三个目标：

1. **恢复原始工程**：目前无可信源码来源，不能承诺从 Mach-O 还原原始工程。
2. **忠实复现可观察体验**：以核验过的 1.6.4 为基准，逐项记录、实现和比对行为及视觉结果。
3. **内部实现与系统适配现代化**：可使用 Swift 6、AppKit/SwiftUI、新权限与登录项机制，不要求沿用原版框架。

原版代码、图标、图片、品牌及其他资源的复用许可仍需单独确认。停止维护、免费发行或找到二进制都不自动授予重新分发权。独立编写实现和资源，不冒充官方版本；这不是法律保证。

## 下一步的验收方式

不应继续凭记忆猜测原版体验或直接扩展自设计界面。先进行参考基线采集：

- 记录触发和关闭条件、等待时间、普通快捷键与鼠标操作下的表现。
- 在固定应用、固定窗口状态、固定显示尺寸及系统外观下采集界面参考。
- 测量布局、分栏顺序、字号、行距、快捷键与标题对齐、窗口位置和边距。
- 盘点实际存在的设置、菜单和其他交互；不把尚未确认的功能写成原版事实。
- 为每项标记“已观察 / 待确认 / 已匹配 / 必要适配差异”。
- 在同一环境中对比新旧版本；系统版本导致的无法复现部分明确记录，不声称像素完全相同。

当前第一版的标题区、页脚、菜单栏入口和设置布局都是独立设计，尚未与原版逐项比对，不能因此宣称复刻完成。本轮只更新研究记录，没有运行原版或更改实现。

## 调查边界

初轮官网、GitHub 和历史存档请求曾失败；本轮已取得上面列明的有效结果，不再将“所有搜索都被网络阻断”作为当前状态。历史存档、其他托管平台、作者本人是否愿意提供源码仍未核验。要取得确定答复，应向 Media Atelier 询问官方仓库或源码快照及其许可。

[1]: https://formulae.brew.sh/api/cask/cheatsheet.json
[2]: original-app-analysis.md
[3]: https://www.mediaatelier.com/CheatSheet/
[4]: https://api.github.com/users/mediaatelier
[5]: https://api.github.com/users/mediaatelier/repos?per_page=100
[6]: https://api.github.com/search/repositories?q=CheatSheet+mediaatelier&per_page=30
[7]: https://api.github.com/search/repositories?q=%22CheatSheet%22+%22Media+Atelier%22+in%3Areadme&per_page=30
[8]: https://api.github.com/search/repositories?q=CheatSheet+%22Stefan+Fuerst%22+in%3Areadme&per_page=5
[9]: https://api.github.com/search/repositories?q=%22com.mediaatelier.CheatSheet%22+in%3Areadme&per_page=30
[10]: https://api.github.com/search/repositories?q=CheatSheet+mediaatelier.com+in%3Areadme&per_page=12&sort=stars
[11]: https://github.com/danielsimons1/cheatsheet
[12]: https://github.com/TakanoriHasebe/CheatSheet
[13]: https://github.com/martongreber/CheatSheet
