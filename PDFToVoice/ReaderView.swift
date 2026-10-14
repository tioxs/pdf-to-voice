import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var reader: ReaderModel
    @State private var showsSettings = false
    @State private var showsSidebar = true
    @State private var pdfMode = false
    @State private var pageInput = "1"
    @State private var query = ""
    @State private var results: [Int] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    let openPDF: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar { sidebar.frame(width: 230); Divider() }
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(reader.fileName).font(.title2.weight(.semibold)).lineLimit(1)
                        Text(reader.isRunningOCR ? "Sayfadaki metin tanınıyor…" : "Sayfa \(reader.currentPageIndex + 1) / \(reader.pageCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Görünüm", selection: $pdfMode) {
                        Text("Metin").tag(false); Text("PDF").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    Button(action: reader.toggleBookmark) {
                        Image(systemName: reader.bookmarks.contains(reader.currentPageIndex) ? "bookmark.fill" : "bookmark")
                    }.help("Sayfaya yer imi ekle").accessibilityLabel("Yer imi")
                }.padding(22)
                Divider()
                readingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let status = reader.statusMessage {
                    HStack { Text(status).font(.caption); Spacer(); Button { reader.statusMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(12).background(.quaternary)
                }
                if reader.isExporting {
                    HStack { ProgressView(value: reader.exportProgress); Text(reader.exportStage).font(.caption); Button("İptal", action: reader.cancelExport) }.padding(12)
                }
                ProgressView(value: reader.readingProgress).tint(.accentColor)
                playbackBar
            }
        }
        .navigationTitle("pdf/voice")
        .onReceive(reader.$currentPageIndex) { pageInput = String($0 + 1) }
        .onChange(of: reader.document) { _ in searchTask?.cancel(); query = ""; results = []; isSearching = false }
        .onDisappear { searchTask?.cancel() }
        .toolbar {
            ToolbarItem { Button { showsSidebar.toggle() } label: { Label("Kenar Çubuğu", systemImage: "sidebar.left") } }
            ToolbarItem { Button(action: openPDF) { Label("PDF Aç", systemImage: "folder") }.keyboardShortcut("o", modifiers: .command) }
            ToolbarItem { Button(action: reader.recognizeCurrentPage) { Label("OCR", systemImage: "text.viewfinder") }.disabled(reader.isRunningOCR) }
            ToolbarItem {
                Menu {
                    Button("Bu Sayfayı Ses Olarak Kaydet") { reader.exportAudio(allPages: false) }
                    Button("Belgeyi Ses Olarak Kaydet") { reader.exportAudio(allPages: true) }
                } label: { Label("Dışa Aktar", systemImage: "square.and.arrow.up") }.disabled(reader.isExporting)
            }
            ToolbarItem { Button { showsSettings.toggle() } label: { Label("Ayarlar", systemImage: "slider.horizontal.3") }.popover(isPresented: $showsSettings) { settings } }
            ToolbarItem { Button(action: reader.closeDocument) { Label("Belgeyi Kapat", systemImage: "xmark") } }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("KÜTÜPHANE", systemImage: "books.vertical").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Belgede ara", text: $query).textFieldStyle(.roundedBorder)
                .onSubmit(performSearch)
                .onChange(of: query) { _ in searchTask?.cancel(); isSearching = false; results = [] }
            if !query.isEmpty {
                Button("Ara", action: performSearch)
                Text(isSearching ? "Aranıyor…" : "\(results.count) sayfa bulundu").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !query.isEmpty {
                        ForEach(results, id: \.self) { page in pageButton(page, icon: "magnifyingglass") }
                    } else {
                        Text("YER İMLERİ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if reader.bookmarks.isEmpty { Text("Dönmek istediğin sayfaları kaydet.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(reader.bookmarks, id: \.self) { page in pageButton(page, icon: "bookmark") }
                        Divider().padding(.vertical, 8)
                        Text("SON BELGELER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(reader.recentDocuments) { item in
                            Button { reader.openRecent(item) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).lineLimit(2)
                                    Text("Sayfa \(item.lastPage + 1)").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 4)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Label("Yerel ve çevrimdışı", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.bar)
    }
    private func pageButton(_ page: Int, icon: String) -> some View {
        Button { reader.selectPage(page) } label: {
            Label("Sayfa \(page + 1)", systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).padding(8)
            .background(page == reader.currentPageIndex ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var readingPanel: some View {
        if pdfMode, let document = reader.document {
            PDFPageView(document: document, pageIndex: reader.currentPageIndex, spokenRange: reader.pdfSpokenRange, selectPage: reader.selectPage)
        } else if reader.pageText.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "text.viewfinder").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Bu sayfada metin bulunamadı.").font(.headline)
                Text("Taranmış sayfaları OCR ile okunabilir hale getir.").foregroundStyle(.secondary)
                if reader.isRunningOCR { ProgressView() }
                else { Button("Metni Tanı", action: reader.recognizeCurrentPage).buttonStyle(.borderedProminent) }
            }.padding(30)
        } else {
            SpokenTextView(text: reader.pageText, spokenRange: reader.spokenRange, fontSize: reader.readingFontSize, readFrom: reader.read)
        }
    }
    private var playbackBar: some View {
        HStack(spacing: 18) {
            Button(action: reader.previousPage) { Image(systemName: "backward.end.fill") }.disabled(!reader.canGoBackward).accessibilityLabel("Önceki sayfa")
            Button(action: reader.togglePlayback) {
                Image(systemName: reader.isSpeaking ? "pause.fill" : "play.fill").frame(width: 22, height: 24)
            }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.space, modifiers: []).disabled(reader.isRunningOCR)
                .help(reader.isSpeaking ? "Duraklat" : "Kaldığın yerden devam et").accessibilityLabel(reader.isSpeaking ? "Duraklat" : "Oynat")
            Button(action: reader.nextPage) { Image(systemName: "forward.end.fill") }.disabled(!reader.canGoForward).accessibilityLabel("Sonraki sayfa")
            Button(action: reader.stop) { Image(systemName: "stop.fill") }.help("Durdur").accessibilityLabel("Durdur")
            Text(reader.speedLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                    Button(minutes == 0 ? "Zamanlayıcıyı Kapat" : "\(minutes) dakika") { reader.setSleepTimer(minutes: minutes) }
                }
            } label: { Image(systemName: reader.sleepDeadline == nil ? "moon" : "moon.fill") }
                .help(reader.sleepDeadline.map { "\($0.formatted(date: .omitted, time: .shortened)) saatinde durur" } ?? "Uyku zamanlayıcısı")
            TextField("Sayfa", text: $pageInput).textFieldStyle(.roundedBorder).frame(width: 54).onSubmit(goToPage)
            Button("Git", action: goToPage)
        }.padding(18).background(.bar)
    }
    private var settings: some View {
        Form {
            Section("Seslendirme") {
                Picker("Ses", selection: Binding(get: { reader.voiceIdentifier ?? "" }, set: { reader.voiceIdentifier = $0.isEmpty ? nil : $0; reader.applySpeechSettings() })) {
                    Text("Otomatik · Belge dili").tag("")
                    ForEach(reader.availableVoices, id: \.identifier) { voice in Text("\(voice.name) · \(voice.language)").tag(voice.identifier) }
                }
                Text("Algılanan dil: \(reader.detectedLanguage.uppercased())").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Hız"); Slider(value: $reader.speechRate, in: 0.35...0.60, step: 0.01) { if !$0 { reader.applySpeechSettings() } }; Text(reader.speedLabel) }
                HStack { Text("Ton"); Slider(value: $reader.pitch, in: 0.75...1.25, step: 0.05) { if !$0 { reader.applySpeechSettings() } } }
                Button("Sesi Dinle", action: reader.previewVoice)
            }
            Section("Okuma") {
                HStack { Text("Yazı"); Slider(value: $reader.readingFontSize, in: 13...30, step: 1); Text("\(Int(reader.readingFontSize)) pt") }
                Toggle("Metinsiz sayfalarda otomatik OCR", isOn: $reader.automaticOCR)
                Toggle("Satır sonlarını ve sayfa numaralarını temizle", isOn: $reader.cleanText).onChange(of: reader.cleanText) { _ in reader.reloadText() }
                Text("Bir kelimeye çift tıkla veya seçip sağ tık → Buradan Oku.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 440, height: 450)
    }
    private func performSearch() {
        searchTask?.cancel()
        let term = query, document = reader.document
        isSearching = true
        searchTask = Task {
            let found = await reader.searchPages(term)
            guard !Task.isCancelled, reader.document === document, query == term else { return }
            results = found; isSearching = false
        }
    }
    private func goToPage() { if let page = Int(pageInput), (1...max(reader.pageCount, 1)).contains(page) { reader.goToPage(page) } }
}
