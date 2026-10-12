# Seednote

Seednote 是一个本地运行的 iPhone 灵感记录原型，最低支持 iOS 18。用户可以主动导入图片、链接或文字，添加想法和录音，在设备上尝试识字与语音转写，并将记录导出为 ZIP。应用没有账号或服务器，也不会监听其他应用的截图。截图入口需要用户主动使用系统分享或快捷指令。

## 打开与构建

1. 用 Xcode 打开 `Seednote.xcodeproj`，选择 **Seednote** scheme 和 iPhone 模拟器运行。
2. 真机运行前，在 Xcode 的 Signing & Capabilities 中选择自己的开发团队；也可以运行 `python3 Tools/generate_project.py --development-team YOUR_TEAM_ID`。
3. `swift test --disable-sandbox` 运行 Core 文件存储测试。iOS 界面测试在 Xcode 的 **Seednote** scheme 中运行。

工程不依赖第三方包。`Resources/Shortcuts/` 包含应用内交付的两份签名快捷指令；`Shortcuts/source/` 保留对应的未签名工作流源文件。快捷指令依赖 bundle ID `com.seednote.app`，修改 ID 后需要重新制作和签名。

## 目录

- `App/`：SwiftUI 界面、音频与图片服务、App Intents。
- `Core/`：本地记录、草稿、媒体保存和导出。
- `Resources/`：图标、权限文案、隐私清单和内置快捷指令。
- `Tests/`、`AppTests/`、`UITests/`：存储、应用和界面测试。
- `Tools/`：Xcode 工程与图标生成脚本。

这是开发源码快照；签名、真机兼容性和 App Store 发布需要分别验收。
