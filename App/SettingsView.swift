import SwiftUI
import AVFoundation
import Speech
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var guide: SeednoteShortcutFile?
    @State private var permission: PermissionInfo?
    @State private var share: SharePayload?
    @State private var errorMessage: String?
    @State private var isExporting = false
    @State private var permissionRevision = 0
    @State private var setupRevision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionCaption(text: L("Capture shortcuts", "捕捉快捷入口"))
                        .padding(.bottom, 10)
                    settingsRow(L("Screenshot to Seednote", "截图并记录到 Seednote"),
                                setupStatus(for: .screenshotShortcut),
                                symbol: "chevron.right") { guide = .screenshot }
                    settingsRow(L("Share to Seednote", "分享素材到 Seednote"),
                                setupStatus(for: .shareShortcut),
                                symbol: "chevron.right") { guide = .share }
                    settingsRow(L("Practice in Seednote", "在 Seednote 内练习"),
                                setupStatus(for: .manual),
                                symbol: "plus") { model.create() }
                    Text(L("Shortcut setup is optional. You can always use New idea in Seednote and return here later.",
                           "快捷入口可以跳过。你可以随时先用 Seednote 里的“记录灵感”，之后再回来设置。"))
                        .font(.caption).foregroundStyle(Theme.muted).padding(.top, 10)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionCaption(text: L("On this iPhone", "在这台 iPhone 上"))
                        .padding(.bottom, 10)
                    settingsRow(L("Microphone", "麦克风"), microphoneStatus,
                                symbol: "chevron.right") { permission = .microphone }
                    settingsRow(L("Transcription", "语音转写"), transcriptionStatus,
                                symbol: "chevron.right") { permission = .transcription }
                    settingsRow(L("Export ideas", "导出灵感"),
                                L("ZIP of text, images and original audio", "文字、图片和原始录音的 ZIP 压缩包"),
                                symbol: "square.and.arrow.up") { exportIdeas() }
                        .disabled(isExporting)
                        .accessibilityIdentifier("exportIdeas")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Your ideas are stored on this iPhone.", "你的灵感保存在这台 iPhone 上。"))
                        .font(.headline)
                    Text(L("Export anything you want to keep before changing phones or removing the app. Removing the app may delete its local data. iPhone backup behavior depends on your system settings.",
                           "换机或卸载 App 前，请导出想保留的资料。卸载可能删除本地数据；iPhone 的系统备份行为取决于你的设备设置。"))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    Text(L("Export creates a copy for you to save or share. Seednote cannot import it back into the app.",
                           "导出会生成一份可保存或分享的副本。Seednote 目前不能把导出资料重新导入 App。"))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 10) {
                    SectionCaption(text: L("About", "关于"))
                    HStack {
                        Text(L("Language", "语言"))
                        Spacer()
                        Text(L("Follows iPhone settings", "跟随 iPhone 设置"))
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    .frame(minHeight: 44)
                    Divider()
                    Text("Seednote \(version)")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 23)
            .padding(.bottom, 34)
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .navigationTitle(L("Settings", "设置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $guide, onDismiss: { setupRevision += 1 }) { ShortcutGuideSheet(guide: $0) }
        .sheet(item: $permission) { PermissionSheet(info: $0) }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                permissionRevision += 1
                setupRevision += 1
            }
        }
        .onAppear { setupRevision += 1 }
        .alert(L("Export failed", "导出失败"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button(L("OK", "知道了"), role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }

    private var microphoneStatus: String {
        _ = permissionRevision
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return L("Allowed · Requested only when you record", "已允许 · 仅在你主动录音时使用")
        case .denied: return L("Off · Open iPhone Settings to allow recording", "未允许 · 可到 iPhone 设置中开启")
        case .undetermined: return L("Not requested · Asked when you record", "尚未请求 · 点击录音时才会询问")
        @unknown default: return L("Status unavailable", "无法读取状态")
        }
    }

    private var transcriptionStatus: String {
        _ = permissionRevision
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return L("Allowed · On-device recognition only", "已允许 · 仅在本机识别")
        case .denied, .restricted: return L("Unavailable · Check iPhone Settings", "不可用 · 请检查 iPhone 设置")
        case .notDetermined: return L("Not requested · On-device only", "尚未请求 · 仅在本机识别")
        @unknown default: return L("Status unavailable", "无法读取状态")
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    private func setupStatus(for origin: CaptureSetupOrigin) -> String {
        _ = setupRevision
        switch CaptureSetupTracker.shared.progress(for: origin).status {
        case .notStarted:
            switch origin {
            case .screenshotShortcut:
                return L("Add, bind a trigger, then save and reopen one capture", "添加后绑定触发方式，再保存并重新打开一条截图记录")
            case .shareShortcut:
                return L("Add when needed, then save and reopen one shared capture", "按需添加，再保存并重新打开一条分享记录")
            case .manual:
                return L("Save and reopen one idea created in Seednote", "保存并重新打开一条在 Seednote 内创建的记录")
            }
        case .savedAwaitingReopen:
            return L("Saved once · Reopen that idea in the library", "已保存一次 · 请在灵感库重新打开该记录")
        case .verified:
            switch origin {
            case .screenshotShortcut, .shareShortcut:
                return L("Saved and reopened once · Reliability not measured", "已保存并重新打开一次 · 尚未测量稳定性")
            case .manual:
                return L("Saved and reopened once on this iPhone", "已在这台 iPhone 上保存并重新打开一次")
            }
        }
    }

    private func settingsRow(_ title: String, _ subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: symbol).font(.subheadline).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func exportIdeas() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                guard let store = model.store else {
                    throw CaptureError.message(L("The local library is unavailable.", "本地资料库无法访问。"))
                }
                let archive = try await Task.detached(priority: .userInitiated) {
                    // Each archive is a full copy of the library; keep only the newest.
                    ExportArchive.removeAll()
                    let folder = try store.export(to: ExportArchive.directory)
                    return try ExportArchive.make(from: folder)
                }.value
                share = SharePayload(items: [archive])
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ShortcutGuideSheet: View {
    let guide: SeednoteShortcutFile
    @Environment(\.dismiss) private var dismiss
    @State private var share: SharePayload?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(guide == .screenshot
                         ? L("Seednote includes a signed shortcut file that takes the current screenshot and passes it to the app.", "Seednote 已内置签名的快捷指令文件，它会截取当前屏幕并把图片传给 App。")
                         : L("Seednote includes a signed shortcut file for images, web links and selected text from the Share menu.", "Seednote 已内置签名的快捷指令文件，可从分享菜单接收图片、网页链接和选中文字。"))
                        .font(.body)
                    Button { openShortcut() } label: {
                        Label(L("Open in Shortcuts", "用“快捷指令”打开"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier(guide == .screenshot ? "openScreenshotShortcut" : "openShareShortcut")
                    Button { shareShortcutFile() } label: {
                        Label(L("Save or share shortcut file", "存到文件或分享"), systemImage: "folder")
                    }
                    .buttonStyle(PillButtonStyle(secondary: true))
                    if guide == .screenshot {
                        step(1, L("Choose Shortcuts in the system menu and confirm Add Shortcut. If Shortcuts is not offered, save the file to Files and open it there.", "在系统菜单中选择“快捷指令”并确认添加。如果没有显示“快捷指令”，请先存到“文件”，再从“文件”中打开。"))
                        step(2, L("Bind it in Settings → Action Button → Shortcut, or Settings → Accessibility → Touch → Back Tap. Choosing it for the Action Button replaces the function currently assigned to that button.", "在“设置 → 操作按钮 → 快捷指令”或“设置 → 辅助功能 → 触控 → 轻点背面”中绑定。为操作按钮选择它时，会替换该按钮当前绑定的功能。"))
                        step(3, L("From a real reading screen, run the trigger, save the idea, then reopen that exact idea from the Seednote library.", "从真实阅读页面触发，保存记录，再从 Seednote 灵感库重新打开同一条记录。"))
                        Text(L("The shortcut can capture iPhone's shortcut status at the top of the screen. For a screenshot without that status, use the iPhone's Side + Volume Up buttons, then share the image to Share to Seednote or save it to Photos and select it in Seednote. Seednote does not automatically crop the top or watch screenshots.",
                               "快捷指令截图可能把屏幕顶部的系统运行提示一起截入。若要取得没有这条提示的原生截图，请按 iPhone 侧边键＋音量上键，再把图片分享到“分享素材到 Seednote”；也可以先存到“照片”，再到 Seednote 选取。Seednote 不会自动裁掉顶部，也不会监听你拍摄的截图。"))
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    } else {
                        step(1, L("Choose Shortcuts in the system menu and confirm Add Shortcut. If needed, save the file to Files and open it there.", "在系统菜单中选择“快捷指令”并确认添加。如有需要，可先存到“文件”，再从“文件”中打开。"))
                        step(2, L("In another app, share an image, web link or selected text and choose Share to Seednote from the actions list.", "在其他 App 中分享图片、网页链接或选中文字，再从操作列表选择“Share to Seednote”。"))
                        step(3, L("Save the received idea, then reopen that exact idea from the Seednote library. Test each material type you plan to use.", "保存收到的记录，再从 Seednote 灵感库重新打开同一条记录。你计划使用的素材类型需要分别测试。"))
                    }
                    Text(L("Opening or adding the file does not mark setup complete. Seednote records only whether one capture from this path was saved and that same record was reopened; it does not claim repeated trigger reliability.",
                           "打开或添加文件不会把设置标为完成。Seednote 只记录这条入口是否有一条记录完成了保存并重新打开；这不代表触发稳定性已经通过多次测试。"))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    Text(L("You can close this guide and keep using New idea without setting up a shortcut.", "你可以关闭本指南，暂不设置快捷入口，继续使用“记录灵感”。"))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(Theme.paper).foregroundStyle(Theme.ink)
            .navigationTitle(guide == .screenshot ? L("Screenshot setup", "截图入口配置") : L("Sharing setup", "分享入口配置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(L("Done", "完成")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
            } }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
            .alert(L("Couldn't open shortcut file", "无法打开快捷指令文件"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button(L("OK", "知道了"), role: .cancel) { errorMessage = nil } }
            message: { Text(errorMessage ?? "") }
        }
    }

    private func openShortcut() {
        do {
            let presented = try ShortcutDocumentPresenter.shared.presentOpenInMenu(for: guide)
            if !presented {
                shareShortcutFile()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareShortcutFile() {
        do {
            share = SharePayload(items: [try guide.bundledURL()])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func step(_ number: Int, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(number)).font(.headline).frame(width: 34, height: 34)
                .background(Theme.surface, in: Circle())
            Text(detail).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum PermissionInfo: String, Identifiable {
    case microphone, transcription
    var id: String { rawValue }
}

private struct PermissionSheet: View {
    let info: PermissionInfo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var statusRevision = 0

    private var status: String {
        _ = statusRevision
        switch info {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return L("Microphone access is allowed.", "麦克风权限已允许。")
            case .denied: return L("Microphone access is off.", "麦克风权限未开启。")
            case .undetermined: return L("Microphone access has not been requested. Seednote asks only after you tap Record.", "尚未请求麦克风权限。只有你点击录音时，Seednote 才会询问。")
            @unknown default: return L("Microphone status is unavailable.", "无法读取麦克风权限状态。")
            }
        case .transcription:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return L("Speech recognition access is allowed.", "语音识别权限已允许。")
            case .denied, .restricted: return L("Speech recognition is unavailable or not allowed.", "语音识别不可用或未获允许。")
            case .notDetermined: return L("Speech recognition access has not been requested.", "尚未请求语音识别权限。")
            @unknown default: return L("Speech recognition status is unavailable.", "无法读取语音识别权限状态。")
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(status).font(.title3)
                    Text(info == .microphone
                         ? L("Recording starts only when you tap Record in the editor. You can still save typed thoughts if access is off.", "只有你在编辑页点击录音，Seednote 才会开始录音。未开启权限时，仍可输入和保存文字。")
                         : L("Transcription is attempted on this device only. Availability also depends on your iPhone and chosen language; your original recording remains if it fails.", "转写只会尝试在本机完成。是否可用还取决于设备和所选语言；转写失败时，原始录音仍会保留。"))
                        .font(.body).foregroundStyle(Theme.muted)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: { Label(L("Open iPhone Settings", "打开 iPhone 设置"), systemImage: "gearshape") }
                        .buttonStyle(PillButtonStyle(secondary: true))
                        .accessibilityIdentifier("openPermissionSettings")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(Theme.paper).foregroundStyle(Theme.ink)
            .navigationTitle(info == .microphone ? L("Microphone", "麦克风") : L("Transcription", "语音转写"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(L("Done", "完成")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
            } }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { statusRevision += 1 }
            }
        }
    }
}

// Creates a local ZIP snapshot; this API does not initiate any network upload.
enum ExportArchive {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeednoteExports", isDirectory: true)

    /// Archives are not removed when the share sheet closes: a destination such as
    /// Save to Files may still be copying. They are cleared at the next export and at launch.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func make(from folder: URL) throws -> URL {
        let destination = folder.appendingPathExtension("zip")
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        coordinator.coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { snapshot in
            result = Result {
                try FileManager.default.copyItem(at: snapshot, to: destination)
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CaptureError.message(L("Could not prepare the export archive.", "无法生成导出压缩包。")) }
        let url = try result.get()
        try? FileManager.default.removeItem(at: folder)
        return url
    }
}
