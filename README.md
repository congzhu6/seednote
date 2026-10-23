# Seednote

Seednote 是一个本地运行的 iPhone 灵感记录原型，最低支持 iOS 18。用户可以主动导入图片、链接或文字，添加想法和录音，在设备上尝试识字与语音转写，并将记录导出为 ZIP。应用没有账号或服务器，也不会监听其他应用的截图。截图入口需要用户主动使用系统分享或快捷指令。

## 打开与构建

1. 用 Xcode 打开 `Seednote.xcodeproj`，选择 **Seednote** scheme 和 iPhone 模拟器运行。
2. 真机运行前，在 Xcode 的 Signing & Capabilities 中选择自己的开发团队；也可以运行 `python3 Tools/generate_project.py --development-team YOUR_TEAM_ID`。
3. `swift test --disable-sandbox` 运行 Core 文件存储测试。iOS 界面测试在 Xcode 的 **Seednote** scheme 中运行。

上传 TestFlight 或 App Store 前运行 `python3 Tools/bump_build.py` 递增构建号（加 `--version 0.2.0` 同时改版本号），然后在 Xcode 中 Product → Archive。App 图标来自 `Resources/Assets.xcassets` 里不含透明通道的 1024 像素图，由 `swift Tools/generate_icons.swift Resources/Assets.xcassets/AppIcon.appiconset` 生成。

工程不依赖第三方包。`Resources/Shortcuts/` 包含应用内交付的两份签名快捷指令；`Shortcuts/source/` 保留对应的未签名工作流源文件。快捷指令依赖 bundle ID `com.seednote.app`，修改 ID 后需要重新制作和签名。

## 测量响应时间

产品需求见 [docs/PRD.md](docs/PRD.md)。PRD 7.1 的两项耗时由 App 自己记录，只记时间和入口类型，不记内容：

- `Screenshot capture → editor` / `Shared material → editor`：从快捷指令动作开始到记录页出现。日志同时给出距进程启动的毫秒数；数值接近总耗时说明是冷启动，远大于总耗时说明是热启动。
- `Save`：从点保存到回到灵感库。

真机连接 Mac 后，在“控制台”App 中选中手机，过滤 `subsystem:com.seednote.app category:Performance` 即可逐次读数；也可以在 Instruments 的 Points of Interest 中查看区间。

## 数据格式

每条正式记录是 `notes/<id>.json`，包含 `schemaVersion`。新增字段时让解码使用默认值即可兼容旧记录；只有旧版本无法正确读取的改动才需要提升版本号。读到更高版本或损坏的文件时，App 会原样保留文件、照常显示其他记录，并在灵感库顶部提示无法读取的数量。

## 目录

- `App/`：SwiftUI 界面、音频与图片服务、App Intents。
- `Core/`：本地记录、草稿、媒体保存和导出。
- `Resources/`：图标、权限文案、隐私清单和内置快捷指令。
- `Tests/`、`AppTests/`、`UITests/`：存储、应用和界面测试。
- `Tools/`：Xcode 工程与图标生成脚本。
- `docs/`：产品需求文档。

这是开发源码快照；签名、真机兼容性和 App Store 发布需要分别验收。
