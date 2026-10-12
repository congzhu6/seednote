import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showWelcome = false
    @State private var search = ""
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showDrafts = false
    @FocusState private var searchFocused: Bool
    private var filtered: [SeedNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.notes : model.notes.filter { $0.searchableText.localizedStandardContains(query) }
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("seednote").font(.custom("Georgia", size: 29, relativeTo: .title)).tracking(-1.3)
                        Spacer()
                        IconButton(symbol: "magnifyingglass", title: L("Search ideas", "搜索灵感")) { showSearch.toggle(); if !showSearch { search = "" }; searchFocused = showSearch }
                            .accessibilityIdentifier("searchIdeas")
                        IconButton(symbol: "slider.horizontal.3", title: L("Settings", "设置")) { showSettings = true }
                    }.padding(.top, 6).id("libraryTop")
                    if showSearch {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                            TextField(L("Search your ideas", "搜索想法与素材"), text: $search).focused($searchFocused)
                                .accessibilityIdentifier("searchField").autocorrectionDisabled()
                            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel(L("Clear search", "清空搜索")) }
                        }.padding(.horizontal, 15).frame(minHeight: 50).background(Theme.surface, in: RoundedRectangle(cornerRadius: 15))
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("Ideas", "灵感")).font(.system(size: 38, weight: .regular, design: .default)).tracking(-1.1)
                        Spacer()
                        if !model.notes.isEmpty { Text("\(model.notes.count)").font(.subheadline).foregroundStyle(Theme.muted).accessibilityLabel(L("\(model.notes.count) saved ideas", "\(model.notes.count) 条已保存灵感")) }
                    }
                    if !model.drafts.isEmpty {
                        Button { showDrafts = true } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "doc.badge.clock")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L("Continue an unfinished idea", "继续未完成的想法")).font(.subheadline.weight(.medium))
                                    Text(L("\(model.drafts.count) draft(s) kept on this iPhone", "这台 iPhone 保留了 \(model.drafts.count) 份草稿")).font(.caption).foregroundStyle(Theme.muted)
                                }; Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityIdentifier("reviewDrafts")
                    }
                    if filtered.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(search.isEmpty ? L("Your next idea\nstarts here.", "下一个想法，\n从这里留下。") : L("No matching ideas", "没有找到相关灵感"))
                                .font(.system(.title, weight: .regular)).tracking(-0.5)
                                .accessibilityLabel(search.isEmpty ? L("Your next idea starts here.", "下一个想法，从这里留下。") : L("No matching ideas", "没有找到相关灵感"))
                            Text(search.isEmpty ? L("Something you read. Something it sparked.\nKeep them together, in your own words.", "一段读到的内容，一个突然冒出的想法。\n把它们放在一起，留下你自己的话。") : L("Try a word from your thought, transcript or source.", "试试想法、转写或素材里的关键词。"))
                                .font(.body).foregroundStyle(Theme.muted).lineSpacing(5)
                        }.padding(.top, 62).padding(.bottom, 100)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { note in
                                NavigationLink { DetailView(noteID: note.id) } label: { LibraryNoteRow(note: note, store: model.store) }
                                    .buttonStyle(.plain).accessibilityIdentifier("noteRow")
                                if note.id != filtered.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 28) }
                            }
                        }.padding(.top, 4)
                    }
                }.padding(.horizontal, 27).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.paper).foregroundStyle(Theme.ink)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                Button { model.create() } label: { Label(L("New idea", "记录灵感"), systemImage: "plus").padding(.horizontal, 12) }
                    .buttonStyle(PillButtonStyle()).frame(maxWidth: 180).padding(.top, 12).padding(.bottom, 13)
                    .accessibilityIdentifier("newIdea")
                    .frame(maxWidth: .infinity).background(Theme.paper.opacity(0.96))
            }
            .navigationDestination(isPresented: $showSettings) { SettingsView().toolbar(.visible, for: .navigationBar) }
            .sheet(item: $model.session) { session in EditorView(session: session).environmentObject(model).interactiveDismissDisabled() }
            .sheet(isPresented: $showDrafts) { DraftPickerView().environmentObject(model) }
            .fullScreenCover(isPresented: $showWelcome) { WelcomeView { hasSeenWelcome = true; showWelcome = false } }
            .alert(L("Couldn't complete that", "未能完成操作"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button(L("OK", "好")) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .onChange(of: model.saveGeneration) { _, _ in
                search = ""; showSearch = false; searchFocused = false
                // Wait for the newly loaded records and cleared search to be laid out.
                Task { @MainActor in
                    await Task.yield()
                    scroll.scrollTo("libraryTop", anchor: .top)
                }
            }
            .onChange(of: model.session?.id) { _, id in if id != nil { showWelcome = false } }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--skip-welcome") { return }
                #endif
                showWelcome = !hasSeenWelcome && model.session == nil
            }
            }
        }
    }
}

struct LibraryNoteRow: View {
    let note: SeedNote
    let store: NoteStore?
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 23
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(note.thought.isEmpty ? (note.transcript.isEmpty ? L("Add your thought", "添加你的想法") : note.transcript) : note.thought)
                .font(.system(size: titleSize, weight: .regular)).tracking(-0.4).lineSpacing(4).lineLimit(4).multilineTextAlignment(.leading)
            if let name = note.imageName, let url = try? store?.assetURL(noteID: note.id, name: name), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill().frame(height: 158).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(L("Saved source image", "已保存的素材图片"))
            } else if !note.sourceText.isEmpty {
                Text(note.sourceText).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading).padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
            }
            HStack(spacing: 8) {
                if let url = validWebURL(note.sourceURL) { Image(systemName: "link"); Text(url.host ?? note.sourceURL).lineLimit(1) }
                else if note.imageName != nil { Image(systemName: "photo"); Text(L("Image", "图片")) }
                else if !note.sourceText.isEmpty { Image(systemName: "text.quote"); Text(L("Selected text", "选中文字")) }
                Text(note.createdAt, style: .date).lineLimit(1)
                Spacer(minLength: 2)
                if note.audioName != nil { Image(systemName: "waveform"); Text(note.audioDuration.clockText) }
            }.font(.caption).foregroundStyle(Theme.muted)
        }.foregroundStyle(Theme.ink).contentShape(Rectangle())
    }
}

struct DraftPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var discard: NoteDraft?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.drafts.filter { $0.id != model.session?.id }) { draft in
                        Button {
                            dismiss()
                            model.open(draft)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(draft.note.thought.isEmpty ? L("Unfinished idea", "未完成的想法") : draft.note.thought).lineLimit(2).foregroundStyle(Theme.ink)
                                Text(draft.note.updatedAt, style: .date).font(.caption).foregroundStyle(Theme.muted)
                            }.padding(.vertical, 8)
                        }.accessibilityIdentifier("resumeDraft")
                            .swipeActions { Button(role: .destructive) { discard = draft } label: { Text(L("Discard", "丢弃")) } }
                    }
                } footer: { Text(L("Only draft content already written to this iPhone can be recovered. Drafts are not in your saved library.", "只能恢复已经写入这台 iPhone 的草稿内容。草稿尚未进入正式灵感库。")) }
            }.navigationTitle(L("Unfinished ideas", "未完成的想法")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done", "完成")) { dismiss() } } }
                .confirmationDialog(L("Discard this draft?", "丢弃这份草稿？"), isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } })) {
                    Button(L("Discard draft", "丢弃草稿"), role: .destructive) { if let discard { model.discardPending(discard) }; discard = nil }
                }
        }
    }
}

struct WelcomeView: View {
    let finish: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("seednote").font(.custom("Georgia", size: 31, relativeTo: .title)).tracking(-1.3).padding(.top, 30)
                Text(L("Keep the\nthought.", "留下当时\n的想法。")).font(.system(size: 54, weight: .regular)).tracking(-2).padding(.top, 22)
                Text(L("Noticed something worth writing about?\nSave what you saw, and what it made you think.", "读到值得写一写的内容？\n把原始素材和它触发的想法一起留下。"))
                    .foregroundStyle(Theme.muted).lineSpacing(5)
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("A small example", "一个小例子")).font(.caption).foregroundStyle(Theme.muted)
                    Text(L("“The best ideas often arrive between tasks.”", "“好想法常常在两件事情之间出现。”")).font(.subheadline).foregroundStyle(Theme.muted)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Text(L("What if my next video began with the moments I usually overlook?", "下条视频，也许可以从那些常被我忽略的瞬间开始。"))
                        .font(.title3).lineSpacing(4)
                    Text(L("Illustration only · not added to your library", "仅用于说明，不会添加到灵感库")).font(.caption2).foregroundStyle(Theme.muted)
                }.padding(22).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                Label(L("Yours, on this iPhone. No account needed.", "保存在你的 iPhone 上，无需注册。"), systemImage: "iphone").font(.subheadline).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }.background(Theme.paper).foregroundStyle(Theme.ink)
            .safeAreaInset(edge: .bottom) { Button(L("Start collecting ideas", "开始记录灵感"), action: finish).buttonStyle(PillButtonStyle()).padding(24).background(Theme.paper) }
    }
}
