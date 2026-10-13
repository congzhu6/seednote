import SwiftUI
import UIKit

struct DetailView: View {
    let noteID: UUID

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var player = AudioPlayer()
    @State private var showWritingCard = false
    @State private var showImage = false
    @State private var confirmDelete = false
    @State private var recordedOpening = false
    @State private var alertMessage: String?
    @ScaledMetric(relativeTo: .title2) private var thoughtSize: CGFloat = 24

    private var note: SeedNote? { model.notes.first { $0.id == noteID } }

    var body: some View {
        Group {
            if let note {
                ScrollView {
                    VStack(alignment: .leading, spacing: 27) {
                        thoughtSection(note)
                        sourceSection(note)
                        if note.audioName != nil || !note.transcript.isEmpty {
                            audioSection(note)
                        }
                        if !note.ocrText.isEmpty { ocrSection(note) }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text(L("Delete idea", "删除灵感"))
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("deleteIdea")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
                .safeAreaInset(edge: .bottom) {
                    Button { showWritingCard = true } label: {
                        Label(L("Use in a draft", "用于写作草稿"), systemImage: "square.on.square")
                    }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("useInDraft")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.paper)
                }
                .toolbar {
                    ToolbarItem(placement: .principal) { Text(L("Your idea", "你的灵感")).font(.headline) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("Edit", "编辑")) { player.stop(); model.edit(note) }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("editIdea")
                    }
                }
                .sheet(isPresented: $showWritingCard) { WritingCardSheet(note: note, sourceImage: image(for: note)) }
                .sheet(isPresented: $showImage) {
                    if let image = image(for: note) {
                        SourceImageViewer(image: image)
                    }
                }
                .confirmationDialog(
                    L("Delete this idea?", "删除这条灵感？"),
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button(L("Delete idea and its media", "删除灵感及其素材"), role: .destructive) {
                        player.stop()
                        do { try model.delete(note); dismiss() }
                        catch { alertMessage = error.localizedDescription }
                    }
                    Button(L("Keep idea", "保留灵感"), role: .cancel) {}
                } message: {
                    Text(L("The saved text, image, and recording for this idea will be removed.", "这条灵感的已保存文字、图片和录音将被移除。"))
                }
            } else {
                ContentUnavailableView(L("Idea unavailable", "灵感不可用"), systemImage: "doc.questionmark",
                                       description: Text(L("It may have been deleted.", "它可能已被删除。")))
            }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .alert(L("Unable to complete action", "操作未完成"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) { Button(L("OK", "知道了"), role: .cancel) { alertMessage = nil } }
        message: { Text(alertMessage ?? "") }
        .onAppear {
            guard !recordedOpening, let note else { return }
            recordedOpening = true
            model.captureTracker.recordOpened(note)
        }
        .onDisappear { player.stop() }
    }

    private func thoughtSection(_ note: SeedNote) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                SectionCaption(text: L("My thought", "我的想法"))
                Text(note.updatedAt, style: .date).font(.caption).foregroundStyle(Theme.muted)
            }
            Text(note.thought.isEmpty ? L("No personal thought yet.", "还没有写下自己的想法。") : note.thought)
                .font(.system(size: thoughtSize, weight: .regular, design: .default))
                .lineSpacing(6)
                .foregroundStyle(note.thought.isEmpty ? Theme.muted : Theme.ink)
                .textSelection(.enabled)
                .accessibilityIdentifier("detailThought")
        }
    }

    private func sourceSection(_ note: SeedNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCaption(text: L("Source", "来源"))
            if let image = StoredImage.thumbnail(assetURL(note.imageName, of: note), filling: CGSize(width: 58, height: 76)) {
                Button { showImage = true } label: {
                    HStack(spacing: 14) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 58, height: 76).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("Source image", "来源图片")).font(.subheadline).foregroundStyle(Theme.muted)
                            Text(L("View original image", "查看原图")).font(.body).foregroundStyle(Theme.ink)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("viewSourceImage")
            } else if note.imageName != nil {
                Text(L("The saved image is unavailable.", "已保存的图片无法访问。"))
                    .foregroundStyle(Theme.red)
            }

            if !note.sourceText.isEmpty {
                Text(note.sourceText).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityIdentifier("sourceText")
            }
            if let url = validWebURL(note.sourceURL) {
                Button { openURL(url) } label: {
                    Label(note.sourceURL, systemImage: "link")
                        .font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("openSourceLink")
            } else if !note.sourceURL.isEmpty {
                Text(L("Saved link is invalid. Edit this idea to correct it.", "保存的链接无效，请编辑这条灵感进行修正。"))
                    .font(.subheadline).foregroundStyle(Theme.red)
            } else if note.imageName != nil || !note.sourceText.isEmpty {
                Text(L("No source link added. Edit to add one.", "未添加原文链接，可通过编辑补充。"))
                    .font(.subheadline).foregroundStyle(Theme.muted)
            } else {
                Text(L("No external source.", "没有外部来源。"))
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }

    private func audioSection(_ note: SeedNote) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let name = note.audioName {
                HStack {
                    Text(L("Original recording", "原始录音"))
                    Spacer()
                    Text(audioURL(for: note) == nil ? L("Unavailable", "无法访问") : (player.isPlaying ? L("Playing", "播放中") : L("Ready to play", "可播放")))
                }
                .font(.subheadline).foregroundStyle(Theme.muted)
                HStack(spacing: 15) {
                    Button { play(name, note: note) } label: {
                        Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                            .frame(width: 48, height: 48)
                            .background(Theme.paper, in: Circle())
                    }
                    .accessibilityLabel(player.isPlaying ? L("Stop recording", "停止播放录音") : L("Play recording", "播放录音"))
                    .accessibilityIdentifier("playRecording")
                    .disabled(audioURL(for: note) == nil)
                    Rectangle().fill(Theme.line).frame(height: 2)
                    Text(note.audioDuration.clockText).font(.subheadline).monospacedDigit()
                }
            }
            if note.audioName != nil && audioURL(for: note) == nil {
                Text(L("The audio file is unavailable. Edit this idea to remove or replace it; your text is kept.", "音频文件无法访问。可通过编辑移除或替换，已有文字仍保留。"))
                    .font(.subheadline).foregroundStyle(Theme.red)
            }
            if !note.transcript.isEmpty {
                Divider()
                SectionCaption(text: L("Voice transcript", "语音转写"))
                Text(note.transcript).font(.body).lineSpacing(4).textSelection(.enabled)
                    .accessibilityIdentifier("detailTranscript")
            } else if note.audioName != nil && ["unavailable", "interrupted", "processing"].contains(note.transcriptStatus) {
                Text(L("Transcription did not finish. Edit this idea to retry when the recording and language support are available.", "转写尚未完成。录音和语言支持可用时，可通过编辑重试。"))
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func ocrSection(_ note: SeedNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: L("Text recognized from source image", "从来源图片识别的文字"))
            Text(note.ocrText).font(.body).textSelection(.enabled)
        }
    }

    /// Full-resolution image, decoded only when a sheet that shows or shares it opens.
    private func image(for note: SeedNote) -> UIImage? {
        assetURL(note.imageName, of: note).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    private func audioURL(for note: SeedNote) -> URL? { assetURL(note.audioName, of: note) }

    // Evaluated during redraws, so it uses the store's lock-free lookup on the loaded record.
    private func assetURL(_ name: String?, of note: SeedNote) -> URL? {
        guard let name else { return nil }
        return model.store?.existingAssetURL(for: note, name: name)
    }

    private func play(_ name: String, note: SeedNote) {
        if player.isPlaying { player.stop(); return }
        do {
            guard let store = model.store else { throw CaptureError.message(L("The local library is unavailable.", "本地资料库无法访问。")) }
            let url = try store.assetURL(noteID: note.id, name: name)
            try player.play(url)
        } catch { alertMessage = error.localizedDescription }
    }
}

private struct WritingCardSheet: View {
    let note: SeedNote
    let sourceImage: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var share: SharePayload?
    @State private var copied = false
    @State private var showImage = false
    @ScaledMetric(relativeTo: .title2) private var thoughtSize: CGFloat = 24

    private var cardText: String {
        var lines = [L("My thought", "我的想法"), note.thought.isEmpty ? L("No personal thought added.", "还没有写下自己的想法。") : note.thought]
        if !note.transcript.isEmpty { lines += ["", L("Voice transcript", "语音转写"), note.transcript] }
        lines += ["", L("Source", "来源")]
        if !note.sourceText.isEmpty { lines.append(note.sourceText) }
        if !note.sourceURL.isEmpty { lines.append(L("Source link: ", "原文链接：") + note.sourceURL) }
        if note.sourceText.isEmpty && note.sourceURL.isEmpty {
            lines.append(note.imageName == nil ? L("No external source.", "没有外部来源。") : L("No source link added.", "未添加原文链接。"))
        }
        if !note.ocrText.isEmpty { lines += ["", L("Text recognized from source image", "从来源图片识别的文字"), note.ocrText] }
        lines += ["", L("Saved ", "保存时间：") + note.updatedAt.formatted(date: .abbreviated, time: .shortened)]
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L("Your thought, with its context.", "把自己的想法连同素材一起带走。"))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    cardPart(L("My thought", "我的想法"), note.thought.isEmpty ? L("No personal thought added.", "还没有写下自己的想法。") : note.thought, large: true)
                    if !note.transcript.isEmpty { cardPart(L("Voice transcript", "语音转写"), note.transcript) }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCaption(text: L("Source", "来源"))
                        if let sourceImage {
                            Button { showImage = true } label: {
                                Image(uiImage: sourceImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: 280)
                                    .accessibilityIdentifier("writingCardImage")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Open source image", "打开来源图片"))
                            .accessibilityIdentifier("writingCardOpenImage")
                        } else if note.imageName != nil {
                            Text(L("The saved image is unavailable.", "已保存的图片无法访问。"))
                                .foregroundStyle(Theme.red)
                        }
                        Text(sourceDescription).font(.body).lineSpacing(4).textSelection(.enabled)
                    }
                    if !note.ocrText.isEmpty { cardPart(L("Text recognized from source image", "从来源图片识别的文字"), note.ocrText) }
                    Text(L("Saved ", "保存时间：") + note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button {
                        UIPasteboard.general.string = cardText
                        copied = true
                    } label: { Label(copied ? L("Text copied", "文字已复制") : L("Copy text", "复制文字"), systemImage: "square.on.square") }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityIdentifier("copyWritingCard")
                    Button {
                        var items: [Any] = [cardText]
                        if let sourceImage { items.append(sourceImage) }
                        share = SharePayload(items: items)
                    } label: {
                        Label(L("Share…", "分享…"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("shareWritingCard")
                }
                .padding(.horizontal, 24).padding(.vertical, 10).background(Theme.paper)
            }
            .background(Theme.paper).foregroundStyle(Theme.ink)
            .navigationTitle(L("Writing card", "写作素材卡"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(L("Done", "完成")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("closeWritingCard")
            } }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
            .sheet(isPresented: $showImage) {
                if let sourceImage { SourceImageViewer(image: sourceImage) }
            }
        }
    }

    private var sourceDescription: String {
        var parts: [String] = []
        if !note.sourceText.isEmpty { parts.append(note.sourceText) }
        if !note.sourceURL.isEmpty { parts.append(note.sourceURL) }
        if parts.isEmpty { parts.append(note.imageName == nil ? L("No external source.", "没有外部来源。") : L("No source link added.", "未添加原文链接。")) }
        return parts.joined(separator: "\n")
    }

    private func cardPart(_ title: String, _ content: String, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCaption(text: title)
            Text(content).font(large ? .system(size: thoughtSize) : .body)
                .lineSpacing(large ? 6 : 4).textSelection(.enabled)
        }
    }
}
