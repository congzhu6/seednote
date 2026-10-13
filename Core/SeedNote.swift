import Foundation

enum CoreText {
    // The localization the system resolved for this app (en or zh-Hans), so text matches the
    // permission prompts and the per-app language chosen in iPhone Settings.
    static var preferredLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static func choose(_ english: String, _ chinese: String, languageCode: String) -> String {
        languageCode.lowercased().hasPrefix("zh") ? chinese : english
    }
    static func date(_ value: Date, languageCode: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: languageCode)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }
}

/// Progress of on-device transcription or image text recognition. Stored in records as
/// its raw string, so existing JSON is unchanged.
public enum RecognitionStatus: String, Sendable {
    case notStarted = ""
    case processing, complete, interrupted, unavailable

    /// The last attempt stopped without a result; the user can retry.
    public var didNotFinish: Bool { self == .interrupted || self == .unavailable }
}

/// The single rule for a saved source link: HTTP(S), a host, and no embedded credentials.
public enum WebLink {
    public static func url(from string: String) -> URL? {
        guard string.count <= 10_000, let components = URLComponents(string: string),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

public struct SeedNote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceURL: String
    public var sourceText: String
    public var thought: String
    public var transcript: String
    public var ocrText: String
    public var imageName: String?
    public var audioName: String?
    public var audioDuration: TimeInterval
    public var origin: String
    public var transcriptStatus: String
    public var ocrStatus: String

    public init(
        id: UUID = UUID(), revision: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date(),
        sourceURL: String = "", sourceText: String = "", thought: String = "", transcript: String = "",
        ocrText: String = "", imageName: String? = nil, audioName: String? = nil,
        audioDuration: TimeInterval = 0, origin: String = "", transcriptStatus: String = "", ocrStatus: String = ""
    ) {
        self.id = id
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceURL = sourceURL
        self.sourceText = sourceText
        self.thought = thought
        self.transcript = transcript
        self.ocrText = ocrText
        self.imageName = imageName
        self.audioName = audioName
        self.audioDuration = audioDuration
        self.origin = origin
        self.transcriptStatus = transcriptStatus
        self.ocrStatus = ocrStatus
    }

    // Records outlive app versions. Only the identity is required; every other field
    // falls back to its default so data written before a field existed still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText) ?? ""
        thought = try container.decodeIfPresent(String.self, forKey: .thought) ?? ""
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText) ?? ""
        imageName = try container.decodeIfPresent(String.self, forKey: .imageName)
        audioName = try container.decodeIfPresent(String.self, forKey: .audioName)
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration) ?? 0
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? ""
        transcriptStatus = try container.decodeIfPresent(String.self, forKey: .transcriptStatus) ?? ""
        ocrStatus = try container.decodeIfPresent(String.self, forKey: .ocrStatus) ?? ""
    }

    public var transcriptState: RecognitionStatus {
        get { RecognitionStatus(rawValue: transcriptStatus) ?? .notStarted }
        set { transcriptStatus = newValue.rawValue }
    }

    public var ocrState: RecognitionStatus {
        get { RecognitionStatus(rawValue: ocrStatus) ?? .notStarted }
        set { ocrStatus = newValue.rawValue }
    }

    public var hasContent: Bool {
        [sourceURL, sourceText, thought, transcript, ocrText].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || imageName != nil || audioName != nil
    }

    public var displayTitle: String { displayTitle(languageCode: CoreText.preferredLanguage) }

    public func displayTitle(languageCode: String) -> String {
        if !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(thought.prefix(80)) }
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(transcript.prefix(80)) }
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(sourceText.prefix(80)) }
        return CoreText.choose("Add your thought", "待补充想法", languageCode: languageCode)
    }

    public var searchableText: String { [thought, transcript, sourceText, sourceURL, ocrText].joined(separator: "\n") }

    public var writingCard: String { writingCard(languageCode: CoreText.preferredLanguage) }

    public func writingCard(languageCode: String) -> String {
        func label(_ english: String, _ chinese: String) -> String {
            CoreText.choose(english, chinese, languageCode: languageCode)
        }
        let emptyThought = label("(not added yet)", "（尚未填写）")
        var lines = ["\(label("My thought: ", "我的想法："))\(thought.isEmpty ? emptyThought : thought)"]
        if !transcript.isEmpty { lines.append("\(label("Transcript: ", "语音转写："))\(transcript)") }
        if !sourceURL.isEmpty { lines.append("\(label("Source link: ", "原文链接："))\(sourceURL)") }
        if !sourceText.isEmpty { lines.append("\(label("Source text: ", "来源文字："))\(sourceText)") }
        if !ocrText.isEmpty { lines.append("\(label("Image text (source): ", "图片识别的来源文字："))\(ocrText)") }
        lines.append("\(label("Saved: ", "保存时间："))\(CoreText.date(updatedAt, languageCode: languageCode))")
        return lines.joined(separator: "\n")
    }
}

public struct NoteDraft: Codable, Identifiable, Sendable {
    public var id: UUID
    public var note: SeedNote
    public var baseRevision: Int?

    public init(id: UUID = UUID(), note: SeedNote = SeedNote(), baseRevision: Int? = nil) {
        self.id = id
        self.note = note
        self.baseRevision = baseRevision
    }
}

public enum AttachmentKind: Sendable { case image, audio }

/// Everything the store could read, plus the files it could not. Unreadable files are
/// reported and left untouched so one damaged record never hides the rest of the library.
public struct NoteLibrary: Sendable {
    public var notes: [SeedNote]
    public var drafts: [NoteDraft]
    public var unreadableFiles: [String]
}

public enum NoteStoreError: Error, Equatable, LocalizedError {
    case notFound
    case conflict
    case invalidInput(String)
    case missingMedia(String)
    case corruptData(String)
    case newerFormat(String)

    public var errorDescription: String? { message(languageCode: CoreText.preferredLanguage) }

    public func message(languageCode: String) -> String {
        func label(_ english: String, _ chinese: String) -> String {
            CoreText.choose(english, chinese, languageCode: languageCode)
        }
        switch self {
        case .notFound: return label("The idea or draft could not be found.", "找不到资料或草稿。")
        case .conflict: return label("This idea changed elsewhere. Reopen it before editing.", "资料已被另一处修改，请重新打开后再编辑。")
        case .invalidInput(let reason):
            let detail: String
            switch reason {
            case "attachmentExtension": detail = label("Unsupported attachment extension.", "附件扩展名无效。")
            case "attachmentSize": detail = label("The attachment is empty or exceeds the size limit.", "附件为空或超过大小限制。")
            case "emptyNote": detail = label("Add a thought or source before saving.", "记录没有内容。")
            case "textLength": detail = label("Text exceeds 100,000 characters.", "文字超过 100,000 字。")
            case "webURL": detail = label("Use a complete HTTP(S) link with a host.", "仅支持带域名的 HTTP(S) 链接。")
            case "mediaDuration": detail = label("Audio duration is invalid or exceeds three minutes.", "音频时长超过三分钟或无效。")
            case "mediaName": detail = label("The attachment name is invalid.", "附件名称无效。")
            default: detail = reason
            }
            return label("Invalid input: ", "输入不符合要求：") + detail
        case .missingMedia(let name): return label("Attachment unavailable: ", "附件不可用：") + name
        case .corruptData(let name): return label("Could not read saved data: ", "资料无法读取：") + name
        case .newerFormat(let name): return label("Saved by a newer Seednote version. Update the app to open: ", "该资料由更新版本的 Seednote 保存，请更新 App 后打开：") + name
        }
    }
}
