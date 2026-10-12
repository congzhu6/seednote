import SwiftUI
import PhotosUI

struct EditorView: View {
    @ObservedObject var session: EditorSession
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var photo: PhotosPickerItem?
    @State private var showSourceInput = false
    @State private var sourceIsLink = true
    @State private var showDiscard = false
    @State private var showRerecord = false
    @State private var showImage = false
    @State private var showDrafts = false
    @FocusState private var thoughtFocused: Bool
    @ScaledMetric(relativeTo: .title2) private var thoughtSize: CGFloat = 25
    private var otherDrafts: Int { model.drafts.filter { $0.id != session.id }.count }
    private var saveUnavailable: Bool {
        (!session.draft.note.hasContent && !session.recorder.isRecording && !session.hasPendingAudio)
        || session.isSaving || session.isImporting || session.isStartingRecording
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if otherDrafts > 0 {
                        Button { thoughtFocused = false; showDrafts = true } label: {
                            HStack { Image(systemName: "tray"); Text(L("\(otherDrafts) other unfinished idea(s)", "另有 \(otherDrafts) 份未完成的想法")); Spacer(); Image(systemName: "chevron.right") }
                                .font(.caption).padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    sourceArea
                    VStack(alignment: .leading, spacing: 8) {
                        SectionCaption(text: L("My thought", "我的想法"))
                        ZStack(alignment: .topLeading) {
                            if session.draft.note.thought.isEmpty {
                                Text(L("This makes me think…", "这让我想到……")).foregroundStyle(Theme.muted.opacity(0.75)).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false)
                            }
                            TextEditor(text: Binding(get: { session.draft.note.thought }, set: { session.change(\.thought, to: $0) }))
                                .frame(minHeight: 155).scrollContentBackground(.hidden)
                                .focused($thoughtFocused).accessibilityLabel(L("My thought", "我的想法")).accessibilityIdentifier("thoughtInput")
                        }.font(.system(size: thoughtSize, weight: .regular)).lineSpacing(5)
                    }
                    if (session.draft.note.audioName != nil || !session.draft.note.transcript.isEmpty) && !session.recorder.isRecording { savedAudio }
                    if session.isRecognizing || !session.draft.note.ocrText.isEmpty {
                        DisclosureGroup(L("Text from image", "图片识别文字")) {
                            if session.isRecognizing { ProgressView().padding() }
                            else { Text(session.draft.note.ocrText).font(.subheadline).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                        }.font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    if session.draft.note.ocrStatus == "interrupted" || session.draft.note.ocrStatus == "unavailable" {
                        Text(L("Image recognition did not finish. Your text is kept. Retry from Image options when the image is available.", "图片识别未完成，已有文字仍保留。图片可用时，可从图片操作中重试。"))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    if session.canSaveAsNew {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("The original idea changed or was deleted. Save these edits as a separate idea to keep both versions.", "原灵感已被修改或删除。可把当前编辑保存为新灵感，不覆盖原记录。"))
                                .font(.subheadline)
                            Button(L("Save as new idea", "另存为新灵感")) { session.saveAsNew() }
                                .frame(minHeight: 44).accessibilityIdentifier("saveAsNewIdea")
                        }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if session.hasPendingAudio {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("The new recording was not attached. Earlier audio and text are unchanged. Retry, or discard this new recording to continue saving.", "新录音尚未添加，原录音和文字保持原样。可重试，或丢弃这次新录音后继续保存。"))
                                .font(.caption).foregroundStyle(Theme.muted)
                            Button(L("Retry recording attachment", "重试添加录音")) { session.retryPendingAudio() }.frame(minHeight: 44)
                            Button(L("Discard new recording", "丢弃这次新录音"), role: .destructive) { session.discardPendingAudio() }.frame(minHeight: 44)
                        }
                    }
                    if let stopNotice = session.recorder.stopNotice {
                        Text(stopNotice).font(.caption).foregroundStyle(Theme.muted)
                    }
                    if session.draftKept {
                        Text(L("Draft kept on this iPhone", "草稿已保存在这台 iPhone 上")).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }.padding(.horizontal, 27).padding(.top, 18).padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.paper).foregroundStyle(Theme.ink)
            .navigationTitle(session.draft.baseRevision == nil ? L("New idea", "记录灵感") : L("Edit idea", "编辑灵感"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel", "取消")) { thoughtFocused = false; showDiscard = true }.accessibilityIdentifier("cancelEditor")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(L("Keep draft for later", "保留草稿，稍后继续"), systemImage: "doc.badge.clock") { model.closeKeeping() }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel(L("More draft options", "更多草稿操作"))
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L("Done", "完成")) { thoughtFocused = false } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingControls }
            .noticeBanner($model.notice)
            .onAppear { model.editorDidAppear(session.id) }
            .onChange(of: photo) { _, value in
                guard let value else { return }
                guard !session.isImporting else { return }
                session.isImporting = true
                Task {
                    defer { session.isImporting = false; photo = nil }
                    do {
                        guard let data = try await value.loadTransferable(type: Data.self) else { throw CaptureError.message(L("The selected image could not be opened.", "无法打开所选图片。")) }
                        await session.importImage(data)
                    } catch { session.errorMessage = error.localizedDescription }
                }
            }
            .sheet(isPresented: $showSourceInput) { SourceInputView(session: session, isLink: sourceIsLink) }
            .sheet(isPresented: $showDrafts) { DraftPickerView().environmentObject(model) }
            .sheet(isPresented: $showImage) {
                if let url = session.asset(session.draft.note.imageName), let image = UIImage(contentsOfFile: url.path) {
                    SourceImageViewer(image: image)
                }
            }
            .confirmationDialog(L("Discard this draft?", "丢弃这份草稿？"), isPresented: $showDiscard, titleVisibility: .visible) {
                Button(L("Discard draft", "丢弃草稿"), role: .destructive) { model.discard() }.accessibilityIdentifier("discardDraft")
                Button(L("Keep editing", "继续编辑"), role: .cancel) {}
            } message: { Text(L("Your saved idea, if any, stays unchanged.", "已有的正式记录会保持原样。")) }
            .confirmationDialog(L("Replace this recording?", "替换这段录音？"), isPresented: $showRerecord, titleVisibility: .visible) {
                Button(L("Record again", "重新录音"), role: .destructive) { Task { await session.startRecording() } }
            } message: { Text(L("A successful new recording will replace this audio and its transcript in this draft. Cancelling this edit keeps the saved original.", "新录音成功后，将替换草稿中的录音和转写。取消编辑仍会保留原正式记录。")) }
            .alert(L("Couldn't complete that", "未能完成操作"), isPresented: Binding(get: { session.errorMessage != nil || session.recorder.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil; session.recorder.errorMessage = nil } })) {
                Button(L("OK", "好")) { session.errorMessage = nil; session.recorder.errorMessage = nil }
            } message: { Text(session.errorMessage ?? session.recorder.errorMessage ?? "") }
        }
    }
    @ViewBuilder private var sourceArea: some View {
        if let name = session.draft.note.imageName, let image = StoredImage.thumbnail(session.asset(name), filling: CGSize(width: 56, height: 65)) {
            HStack(spacing: 13) {
                Button { showImage = true } label: {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 65).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                }.accessibilityLabel(L("Open source image", "打开素材图片"))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("A thought starts here", "想法从这里开始")).font(.subheadline.weight(.medium))
                    Text(L("Your selected image", "你选中的图片")).font(.caption).foregroundStyle(Theme.muted)
                }; Spacer()
                Menu {
                    Button(L("Read text from image", "识别图片文字"), systemImage: "text.viewfinder") { session.recognizeImage() }.disabled(session.isRecognizing)
                    Button(L("Remove image", "移除图片"), systemImage: "trash", role: .destructive) { session.removeImage() }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel(L("Image options", "图片操作"))
            }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        } else if session.draft.note.imageName != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("This image is unavailable. Your text is still editable. Remove the missing image or choose a replacement before saving.", "这张图片无法访问，文字仍可编辑。保存前请移除缺失图片，或选择替换图片。"))
                    .font(.subheadline).foregroundStyle(Theme.red)
                HStack {
                    Button(L("Remove missing image", "移除缺失图片"), role: .destructive) { session.removeImage() }
                        .frame(minHeight: 44).accessibilityIdentifier("removeMissingImage")
                    PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                        Text(L("Replace image", "替换图片")).frame(minHeight: 44)
                    }.disabled(session.isImporting)
                }
            }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        if !session.draft.note.sourceURL.isEmpty {
            Button { sourceIsLink = true; showSourceInput = true } label: {
                HStack(spacing: 12) { Image(systemName: "link"); Text(session.draft.note.sourceURL).lineLimit(2).multilineTextAlignment(.leading); Spacer(); Image(systemName: "pencil").font(.caption) }
                    .font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
        }
        if !session.draft.note.sourceText.isEmpty {
            Button { sourceIsLink = false; showSourceInput = true } label: {
                HStack(alignment: .top) { Image(systemName: "text.quote"); Text(session.draft.note.sourceText).lineLimit(3).multilineTextAlignment(.leading); Spacer(minLength: 0) }
                    .font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
        }
        if typeSize.isAccessibilitySize {
            HStack(spacing: 24) {
                PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo").font(.system(size: 22)).frame(width: 44, height: 44)
                }.accessibilityLabel(L("Add image", "添加图片")).disabled(session.isImporting)
                IconButton(symbol: "link", title: L("Add source link", "添加来源链接")) { sourceIsLink = true; showSourceInput = true }
                IconButton(symbol: "text.quote", title: L("Add source text", "添加来源文字")) { sourceIsLink = false; showSourceInput = true }
                if session.isImporting { ProgressView() }
            }.foregroundStyle(Theme.muted)
        } else {
        HStack(spacing: 22) {
            PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) { Label(L("Image", "图片"), systemImage: "photo").frame(minHeight: 44) }.disabled(session.isImporting)
            Button { sourceIsLink = true; showSourceInput = true } label: { Label(L("Link", "链接"), systemImage: "link").frame(minHeight: 44) }
            Button { sourceIsLink = false; showSourceInput = true } label: { Label(L("Text", "文字"), systemImage: "text.quote").frame(minHeight: 44) }
            if session.isImporting { ProgressView() }
        }.font(.subheadline).foregroundStyle(Theme.muted)
        }
    }
    private var savedAudio: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.draft.note.audioName != nil {
            HStack(spacing: 12) {
                Button { session.playAudio() } label: { Image(systemName: session.player.isPlaying ? "pause.fill" : "play.fill").frame(width: 46, height: 46).background(Theme.surface, in: Circle()) }.accessibilityLabel(session.player.isPlaying ? L("Pause recording", "暂停录音") : L("Play recording", "播放录音")).disabled(session.asset(session.draft.note.audioName) == nil)
                VStack(alignment: .leading, spacing: 4) { Text(L("Your recording", "你的录音")).font(.subheadline); Text(session.draft.note.audioDuration.clockText).font(.caption).foregroundStyle(Theme.muted) }
                Spacer()
                Button { thoughtFocused = false; showRerecord = true } label: { Image(systemName: "arrow.trianglehead.clockwise").frame(width: 44, height: 44) }.accessibilityLabel(L("Record again", "重新录音"))
            }
            if session.asset(session.draft.note.audioName) == nil {
                Text(L("The recording is unavailable. Remove it or record a replacement before saving. Existing text will be kept.", "录音无法访问。保存前请移除它或重新录音，已有文字仍会保留。"))
                    .font(.caption).foregroundStyle(Theme.red)
                Button(L("Remove missing recording", "移除缺失录音"), role: .destructive) { session.removeAudio() }
                    .frame(minHeight: 44).accessibilityIdentifier("removeMissingAudio")
            }
            HStack {
                Picker(L("Transcription language", "转写语言"), selection: $session.speechLocale) { Text("English").tag("en-US"); Text("简体中文").tag("zh-CN") }.pickerStyle(.menu).labelsHidden().font(.subheadline)
                Spacer()
                Button { session.transcribe() } label: {
                    if session.isTranscribing { ProgressView().padding(12) }
                    else { Text(L("Transcribe on device", "本机转写")).font(.subheadline).frame(minHeight: 44) }
                }.disabled(session.isTranscribing || session.recorder.isRecording || session.asset(session.draft.note.audioName) == nil)
            }
            Text(L("Choose the language spoken in this recording. Transcription writes those words; it does not translate them.",
                   "请选择录音中实际说的语言。本机转写会写出这门语言的原话，不会翻译。"))
                .font(.caption).foregroundStyle(Theme.muted)
            }
            if !session.draft.note.transcript.isEmpty {
                SectionCaption(text: L("Transcript · editable", "转写 · 可编辑"))
                TextEditor(text: Binding(get: { session.draft.note.transcript }, set: { session.change(\.transcript, to: $0) })).font(.body).frame(minHeight: 110).scrollContentBackground(.hidden).accessibilityLabel(L("Transcript", "转写内容"))
            }
            if session.draft.note.transcriptStatus == "interrupted" || session.draft.note.transcriptStatus == "unavailable" {
                Text(L("Transcription did not finish. Your existing text is kept. You can retry when the recording and on-device language support are available.", "转写未完成，已有文字仍保留。录音和本机语言支持可用时，可以重试。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            } else if session.asset(session.draft.note.audioName) != nil {
                Text(L("The original audio is kept. Transcription needs on-device language support.", "保留原始录音。转写需要设备支持对应语言的本机识别。")).font(.caption).foregroundStyle(Theme.muted)
            }
        }.padding(.top, 2)
    }
    private var recordingControls: some View {
        VStack(spacing: 16) {
            if session.recorder.isRecording {
                VStack(spacing: 18) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Recording your thought", "正在记录你的想法")).font(.caption).foregroundStyle(Theme.muted)
                            RecordingDuration(recorder: session.recorder)
                        }; Spacer()
                        Button { session.stopRecording() } label: { Image(systemName: "stop.fill").font(.system(size: 21)).foregroundStyle(Theme.paper).frame(width: 66, height: 66).background(Theme.red, in: Circle()) }.accessibilityLabel(L("Stop recording", "停止录音"))
                    }
                    RecordingLevel(recorder: session.recorder)
                    Text(L("Up to 3 minutes · original audio kept", "最长 3 分钟 · 保留原始音频")).font(.caption).foregroundStyle(Theme.muted)
                }.padding(22).background(Theme.surface, in: RoundedRectangle(cornerRadius: 27))
            } else if session.draft.note.audioName == nil && !thoughtFocused && typeSize.isAccessibilitySize {
                Button { Task { await session.startRecording() } } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "mic.fill").font(.system(size: 25)).foregroundStyle(Theme.paper).frame(width: 66, height: 66).background(Theme.red, in: Circle())
                        Text(L("Record", "录音")).font(.body)
                        Spacer(minLength: 0)
                    }.padding(14).frame(maxWidth: .infinity).background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
                }.accessibilityLabel(L("Record my thought", "录下我的想法")).accessibilityIdentifier("recordThought").disabled(session.isStartingRecording)
            } else if session.draft.note.audioName == nil && !thoughtFocused {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Say it while it’s fresh.", "趁想法还在，说出来。")).font(.body)
                        Text(L("Tap to record your thought", "点击录下你的想法")).font(.caption).foregroundStyle(Theme.muted)
                    }; Spacer()
                    Button { thoughtFocused = false; Task { await session.startRecording() } } label: {
                        Image(systemName: "mic.fill").font(.system(size: 25)).foregroundStyle(Theme.paper).frame(width: 66, height: 66).background(Theme.red, in: Circle())
                    }.accessibilityLabel(L("Record my thought", "录下我的想法")).accessibilityIdentifier("recordThought").disabled(session.isStartingRecording)
                }.padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 27))
            }
            Button { thoughtFocused = false; session.save() } label: {
                if session.isSaving { ProgressView().tint(Theme.ink) }
                else { Text(session.recorder.isRecording ? L("Stop & save idea", "停止并保存灵感") : L("Save idea", "保存灵感")) }
            }.buttonStyle(PillButtonStyle(secondary: saveUnavailable)).accessibilityIdentifier("saveIdea")
                .disabled(saveUnavailable)
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12).background(Theme.paper)
    }
}

/// Only these views observe the meter values that change ten times a second while recording.
private struct RecordingDuration: View {
    @ObservedObject var recorder: AudioRecorder
    var body: some View {
        Text(recorder.duration.clockText).font(.system(size: 48, weight: .light, design: .monospaced)).monospacedDigit()
    }
}

private struct RecordingLevel: View {
    @ObservedObject var recorder: AudioRecorder
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.line).overlay(alignment: .leading) { Capsule().fill(Theme.red).frame(width: max(4, geometry.size.width * CGFloat(recorder.power))) }
        }.frame(height: 4).accessibilityLabel(L("Microphone level", "麦克风音量"))
    }
}

struct SourceInputView: View {
    @ObservedObject var session: EditorSession
    let isLink: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(isLink ? L("Keep the source", "保留原文链接") : L("Save a passage", "保留原文片段")).font(.title2)
                Text(isLink ? L("Paste the article’s full web address.", "粘贴文章的完整网页地址。") : L("Paste or type the words that sparked your idea.", "粘贴或输入触发你想法的原文。" )).foregroundStyle(Theme.muted)
                TextEditor(text: $value).font(.body).scrollContentBackground(.hidden).frame(minHeight: 130).padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14)).textInputAutocapitalization(.never).autocorrectionDisabled(isLink)
                    .accessibilityLabel(isLink ? L("Source link", "来源链接") : L("Source text", "原文片段"))
                // UIPasteControl asks for user intent through a visible tap. No clipboard inspection on appear.
                PasteButton(payloadType: String.self) { strings in if let text = strings.first { value = text } }.labelStyle(.titleAndIcon)
                Spacer(minLength: 0)
            }.padding(24).background(Theme.paper)
                .navigationTitle(isLink ? L("Source link", "来源链接") : L("Source text", "原文片段")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { do { try session.setSource(value, asLink: isLink); dismiss() } catch { self.error = error.localizedDescription } } }
                }
                .onAppear { value = isLink ? session.draft.note.sourceURL : session.draft.note.sourceText }
                .alert(L("Check the source", "检查素材"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button(L("OK", "好")) { error = nil } } message: { Text(error ?? "") }
        }
    }
}
