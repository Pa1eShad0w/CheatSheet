# 经典 CheatSheet 1.6.4：只读分析

分析日期：2026-10-27。目的：确认安装包身份、理解产品职责，并确定独立实现的技术路线。没有启动原版，没有反编译复用其实现，也没有复制其代码、图标或资源进入本工程。

## 安装包身份

文件：`~/Downloads/cheatsheet-mac.dmg`。

[Homebrew Cask 元数据](https://formulae.brew.sh/api/cask/cheatsheet.json) 记录版本 `1.6.4`，SHA-256 为：

```text
0af341585bc93a6935266e280c2661642cd8496ceb37ccad4056ecf2f002ea34
```

本地文件 SHA-256 完全匹配。`file` 将其内容识别为 bzip2 压缩数据；这不是无效 DMG 的证据，`hdiutil attach -readonly -nobrowse -noautoopen` 成功验证磁盘映像校验和并只读挂载。

其他候选文件：

| 文件 | 检查结果 |
| --- | --- |
| `1.6.4.dmg`、`1.6.4 (1).dmg` | 实际为 HTML 网页，不是磁盘映像 |
| `CheatSheet 1.6.4.dmg` | SHA-256 不同；未将其作为可信分析对象 |
| `cheatsheet15.zip` | 不匹配 1.6.4 DMG 的哈希；不能据此判断其他版本是否真实 |

匹配历史哈希证明它与 Homebrew 记录的字节一致，不代表它符合今天的分发或运行要求。

## 应用元数据和签名

直接检查 `Info.plist`、Mach-O 头、动态库依赖和代码签名得到：

| 项目 | 值 |
| --- | --- |
| Bundle identifier | `com.mediaatelier.CheatSheet` |
| 版本 / build | `1.6.4` / `1.6.4` |
| 最低系统版本 | macOS `10.10` |
| 构建 SDK | macOS `11.0`，Xcode `12.2` |
| CPU 架构 | `x86_64` 和 `arm64`，通用二进制 |
| 应用类型 | `LSUIElement = true`，菜单栏/后台辅助应用 |
| 签名者 | `Developer ID Application: Stefan Fuerst (2295B9BX7F)` |
| 签名时间戳 | 2022-09-24 |
| 静态签名校验 | `codesign --verify --deep --strict` 通过 |
| Runtime | 启用了 hardened runtime |

因此，**不能把经典版笼统描述为“仅支持 Intel”或“签名损坏”**。本次没有启动它，不能声称它在当前 macOS 上一定失败、一定成功，或已经找到具体兼容性故障。

此前安装在 `/Applications/CheatSheet.app` 的 `com.jinso.cheatsheet`、版本 `1.0.2` 是另一应用，不是本节描述的原版。

## 依赖与资源

`otool -L` 显示系统依赖包含 AppKit/Cocoa、ApplicationServices、Carbon、WebKit、ServiceManagement 和 Security；内置 Framework 包含：

- `AccessKit.framework`
- `Sparkle.framework`
- `Sentry.framework`
- `RepliesSDK.framework`

资源包含帮助页、图标、图片、默认配置和界面资源。默认配置中的等待值为 `1`。这些足以说明旧包的技术构成，但不足以推断全部内部实现。特别是，发现 WebKit 依赖不等于已经证实所有面板都用 HTML 渲染。

安装包不提供可直接构建的源码工程。提取 Mach-O 只能得到编译产物；反汇编无法可靠恢复原始工程、命名、注释和构建设置。

## 新实现的决策

1. **重新实现功能，而非补签名、重打包或复用旧实现。** 原版已支持 arm64；重建的价值是现代、可维护的源码和明确的权限/并发处理，不是简单更换 CPU 架构。
2. 用 AppKit 管理事件、菜单栏和非激活 `NSPanel`，SwiftUI 渲染列表与设置。
3. Accessibility 属性只读访问；不使用 AppleScript、菜单点击、注入或私有系统接口。
4. 不携带原版更新、遥测和支持框架；首版无第三方依赖。
5. 独立名称、bundle identifier 和原创图标，不声称为 Media Atelier 官方版本。
6. 最低 macOS 14，Swift 6；原生或通用构建，正式分发需自己的 Developer ID 和公证。

该路线不依赖原版的源码恢复。产品交互参考经典工具的用途；本项目的实现和资源独立编写。
