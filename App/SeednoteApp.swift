import SwiftUI

@main struct SeednoteApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(model).tint(Theme.ink)
                .onChange(of: phase) { _, newPhase in
                    if newPhase == .background {
                        if model.session?.recorder.isRecording == true {
                            model.session?.recorder.stopNotice = L("Recording stopped when Seednote left the foreground. Your recorded audio was kept.", "Seednote 离开前台后已停止录音，已录下的音频会保留。")
                        }
                        model.session?.stopRecording()
                        do { try model.session?.flush() } catch { model.session?.errorMessage = error.localizedDescription }
                    }
                }
        }
    }
}
