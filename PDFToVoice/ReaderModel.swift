import AVFoundation
import PDFKit
import CryptoKit
import NaturalLanguage
import UniformTypeIdentifiers
import SwiftUI
@preconcurrency import Vision

@MainActor
final class ReaderModel: NSObject, ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var fileName = ""
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var pageText = ""
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRunningOCR = false
    @Published private(set) var recentDocuments: [RecentDocument] = []
    @Published var errorMessage: String?
    @Published var voiceIdentifier: String? { didSet { defaults.set(voiceIdentifier, forKey: Keys.voice) } }
    @Published var speechRate: Float { didSet { defaults.set(speechRate, forKey: Keys.rate) } }
    @Published var pitch: Float { didSet { defaults.set(pitch, forKey: Keys.pitch) } }
    @Published var readingFontSize: Double { didSet { defaults.set(readingFontSize, forKey: Keys.fontSize) } }

    @Published var automaticOCR = true { didSet { defaults.set(automaticOCR, forKey: "reader.autoOCR") } }
    @Published var cleanText = true { didSet { defaults.set(cleanText, forKey: "reader.cleanText") } }
    @Published private(set) var bookmarks: [Int] = []
    @Published private(set) var resumeOffset = 0
    @Published private(set) var sleepDeadline: Date?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = 0.0
    @Published var statusMessage: String?
    private var documentKey = ""
    private var activeUtterance: AVSpeechUtterance?
    private var ocrTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var ocrToken = UUID()
    private var cachedOCR: [String: String] = [:]
    private var exporter: AudioExporter?
    private var exportTask: Task<Void, Never>?
    @Published private(set) var exportStage = "Ses hazırlanıyor"
    private var lastPositionSave = Date.distantPast
    private var excludedEdges: Set<String> = []
    private var sourceOffsets: [Int] = []
    private var cacheURL: URL? {
        cacheDirectory?.appendingPathComponent("\(documentKey).json")
    }

    struct RecentDocument: Identifiable, Codable, Hashable {
        let bookmark: Data
        let name: String
        let lastPage: Int
        var key: String? = nil
        var offset: Int? = nil
        var id: Data { bookmark }
    }

    private enum Keys {
        static let voice = "reader.voice"
        static let rate = "reader.rate"
        static let pitch = "reader.pitch"
        static let recent = "reader.recent"
        static let fontSize = "reader.fontSize"
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let defaults: UserDefaults
    private let makeBookmark: (URL) throws -> Data
    private let cacheDirectory: URL?
    private var securityScopedURL: URL?
    private var shouldAdvance = false
    private var utteranceOffset = 0
    private var loadTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil, makeBookmark: @escaping (URL) throws -> Data = {
        try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }) {
        self.defaults = defaults
        self.makeBookmark = makeBookmark
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("PDFToVoice/OCR")
        voiceIdentifier = defaults.string(forKey: Keys.voice)
        speechRate = defaults.object(forKey: Keys.rate) as? Float ?? 0.48
        pitch = defaults.object(forKey: Keys.pitch) as? Float ?? 1
        readingFontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 18
        automaticOCR = defaults.object(forKey: "reader.autoOCR") as? Bool ?? true
        cleanText = defaults.object(forKey: "reader.cleanText") as? Bool ?? true
        super.init()
        synthesizer.delegate = self
        if let data = defaults.data(forKey: Keys.recent),
           let items = try? JSONDecoder().decode([RecentDocument].self, from: data) {
            recentDocuments = items
        }
    }

    deinit {
        loadTask?.cancel(); ocrTask?.cancel(); sleepTask?.cancel(); exportTask?.cancel()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    var pageCount: Int { document?.pageCount ?? 0 }
    var canGoBackward: Bool { currentPageIndex > 0 }
    var canGoForward: Bool { currentPageIndex + 1 < pageCount }
    var speedLabel: String {
        let multiplier: Double
        if speechRate <= 0.48 {
            multiplier = 0.5 + Double((speechRate - 0.35) / 0.13) * 0.5
        } else {
            multiplier = 1 + Double((speechRate - 0.48) / 0.12)
        }
        return String(format: "%.1f×", multiplier)
    }
    var spokenLocation: Int? { spokenRange?.location }

    var availableVoices: [AVSpeechSynthesisVoice] {
        let preferred = Locale.current.language.languageCode?.identifier ?? "tr"
        return AVSpeechSynthesisVoice.speechVoices().sorted {
            let a = $0.language.hasPrefix(preferred), b = $1.language.hasPrefix(preferred)
            if a != b { return a }
            return $0.language == $1.language
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.language < $1.language
        }
    }

    var detectedLanguage: String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(pageText)
        return recognizer.dominantLanguage?.rawValue ?? "tr"
    }
    var readingProgress: Double {
        guard pageCount > 0 else { return 0 }
        let fraction = Double(resumeOffset) / Double(max((pageText as NSString).length, 1))
        return (Double(currentPageIndex) + fraction) / Double(pageCount)
    }
    func toggleBookmark() {
        if bookmarks.contains(currentPageIndex) { bookmarks.removeAll { $0 == currentPageIndex } }
        else { bookmarks.append(currentPageIndex); bookmarks.sort() }
        defaults.set(bookmarks, forKey: "reader.bookmarks." + documentKey)
    }
    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        sleepDeadline = minutes > 0 ? Date().addingTimeInterval(Double(minutes * 60)) : nil
        guard minutes > 0 else { return }
        sleepTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000) }
            catch { return }
            self?.stop(); self?.sleepDeadline = nil
        }
    }
    func reloadText() {
        stop(); resumeOffset = 0; loadCurrentPageText(); updateRecentPage()
    }
    func read(from offset: Int) {
        stop(); resumeOffset = offset; speakCurrentPage(from: offset)
    }
    func searchPages(_ query: String) async -> [Int] {
        guard let document, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var result: [Int] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return [] }
            let text = cachedOCR[String(index)] ?? document.page(at: index)?.string ?? ""
            if text.localizedCaseInsensitiveContains(query) { result.append(index) }
            if index % 10 == 0 { await Task.yield() }
        }
        return result
    }
    private func cancelOCR() {
        ocrToken = UUID(); ocrTask?.cancel(); ocrTask = nil; isRunningOCR = false
    }

    func open(_ url: URL, page: Int? = nil) {
        loadTask?.cancel()
        cancelOCR()
        stop()
        isLoading = true; statusMessage = nil; errorMessage = nil
        let hasAccess = url.startAccessingSecurityScopedResource()
        loadTask = Task { [weak self] in
            let pdf = await Task.detached(priority: .userInitiated) { PDFDocument(url: url) }.value
            guard let self, !Task.isCancelled else {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                return
            }
            isLoading = false
            guard let pdf, pdf.pageCount > 0, !pdf.isLocked else {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                errorMessage = "Dosya boş, bozuk veya parola korumalı olabilir."
                return
            }
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = hasAccess ? url : nil
            document = pdf
            fileName = url.deletingPathExtension().lastPathComponent
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let identity = url.standardizedFileURL.path
            documentKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let fingerprint = "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if defaults.string(forKey: "reader.fingerprint." + documentKey) != fingerprint {
                if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
                defaults.set(fingerprint, forKey: "reader.fingerprint." + documentKey)
            }
            cachedOCR = cacheURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            bookmarks = defaults.array(forKey: "reader.bookmarks." + documentKey) as? [Int] ?? []
            bookmarks = bookmarks.filter { (0..<pdf.pageCount).contains($0) }
            let savedItem = recentDocuments.first { $0.key == self.documentKey }
            currentPageIndex = min(max(page ?? savedItem?.lastPage ?? 0, 0), pdf.pageCount - 1)
            resumeOffset = savedItem?.offset ?? 0
            prepareExcludedEdges()
            loadCurrentPageText()
            resumeOffset = min(resumeOffset, (pageText as NSString).length)
            remember(url)
        }
    }

    func openRecent(_ item: RecentDocument) {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: item.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            open(url, page: item.lastPage)
        } catch { errorMessage = "Son kullanılan PDF açılamadı: \(error.localizedDescription)" }
    }

    func clearRecentDocuments() {
        recentDocuments.removeAll()
        defaults.removeObject(forKey: Keys.recent)
    }

    func selectPage(_ index: Int) {
        guard index != currentPageIndex, (0..<pageCount).contains(index) else { return }
        cancelOCR(); stop(); currentPageIndex = index; resumeOffset = 0; loadCurrentPageText(); updateRecentPage()
    }
    func closeDocument() {
        loadTask?.cancel(); cancelOCR(); stop(); isLoading = false; setSleepTimer(minutes: 0); securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil; document = nil; fileName = ""; currentPageIndex = 0; pageText = ""; resumeOffset = 0; bookmarks = []; cachedOCR = [:]
    }
    func previousPage() { if canGoBackward { selectPage(currentPageIndex - 1) } }
    func nextPage() { if canGoForward { selectPage(currentPageIndex + 1) } }
    func goToPage(_ pageNumber: Int) { selectPage(pageNumber - 1) }
    func togglePlayback() {
        if isPaused {
            if activeUtterance == nil { speakCurrentPage(from: resumeOffset) }
            else { synthesizer.continueSpeaking() }
        }
        else if isSpeaking { synthesizer.pauseSpeaking(at: .word) }
        else { speakCurrentPage(from: resumeOffset) }
    }
    func stop() {
        cancelOCR()
        updateRecentPage()
        activeUtterance = nil
        shouldAdvance = false; synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false; isPaused = false; spokenRange = nil
    }
    func previewVoice() {
        stop()
        let utterance = makeUtterance(detectedLanguage == "tr" ? "Merhaba, seçtiğiniz ses böyle duyuluyor." : "Hello, this is your selected reading voice.")
        activeUtterance = utterance; isSpeaking = true
        synthesizer.speak(utterance)
    }

    func applySpeechSettings() {
        guard isSpeaking || isPaused else { return }
        guard shouldAdvance || isPaused else { stop(); return }
        let offset = spokenRange?.location ?? resumeOffset
        let wasPaused = isPaused
        stop(); resumeOffset = offset
        if wasPaused { isPaused = true }
        else { speakCurrentPage(from: offset) }
    }

    func recognizeCurrentPage() { recognizeCurrentPage(continueReading: false) }
    private func recognizeCurrentPage(continueReading: Bool) {
        guard let page = document?.page(at: currentPageIndex), !isRunningOCR else { return }
        stop(); isRunningOCR = true
        let token = UUID(); ocrToken = token
        let index = currentPageIndex, key = documentKey
        let image = page.thumbnail(of: CGSize(width: 2400, height: 3200), for: .mediaBox)
        ocrTask = Task { [weak self] in
            let text = await Self.recognize(image: image)
            guard let self, !Task.isCancelled, ocrToken == token,
                  documentKey == key, currentPageIndex == index else { return }
            isRunningOCR = false
            if text.isEmpty {
                errorMessage = "Bu sayfada OCR ile metin bulunamadı. Sonraki sayfaya geçebilirsiniz."
            } else {
                cachedOCR[String(index)] = text
                if let cacheURL, let data = try? JSONEncoder().encode(cachedOCR) {
                    do {
                        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: cacheURL, options: .atomic)
                    } catch { statusMessage = "OCR metni hazır, ancak önbelleğe kaydedilemedi." }
                }
                loadCurrentPageText(); resumeOffset = 0; updateRecentPage()
                if continueReading { speakCurrentPage() }
            }
        }
    }
    private func prepareExcludedEdges() {
        guard let document, pageCount >= 3 else { excludedEdges = []; return }
        var counts: [String: Int] = [:]
        for index in 0..<min(pageCount, 50) {
            let lines = (document.page(at: index)?.string ?? "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for edge in Set([lines.first, lines.last].compactMap { $0?.trimmingCharacters(in: .whitespaces) }) {
                counts[edge, default: 0] += 1
            }
        }
        excludedEdges = Set(counts.filter { $0.value >= max(3, min(pageCount, 50) / 2) }.map(\.key))
    }
    var pdfSpokenRange: NSRange? {
        guard cachedOCR[String(currentPageIndex)] == nil, let spokenRange,
              spokenRange.length > 0, NSMaxRange(spokenRange) <= sourceOffsets.count else { return nil }
        let first = sourceOffsets[spokenRange.location]
        let last = sourceOffsets[NSMaxRange(spokenRange) - 1]
        return NSRange(location: first, length: last - first + 1)
    }
    private func loadCurrentPageText() {
        let raw = cachedOCR[String(currentPageIndex)] ?? document?.page(at: currentPageIndex)?.string ?? ""
        let result = Self.processText(raw, clean: cleanText, excluding: excludedEdges)
        pageText = result.text; sourceOffsets = result.offsets; spokenRange = nil
    }
    static func normalizedText(_ raw: String, excluding edges: Set<String> = []) -> String {
        processText(raw, clean: true, excluding: edges).text
    }
    /// Keep UTF-16 source indices so cleaned speech still highlights the correct PDF occurrence.
    static func processText(_ raw: String, clean: Bool, excluding edges: Set<String> = []) -> (text: String, offsets: [Int]) {
        let source = raw as NSString
        let value = NSMutableString(string: raw)
        var offsets = Array(0..<source.length)
        var removals: [NSRange] = []
        if clean {
            let lines = raw.components(separatedBy: "\n")
            let nonempty = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var start = 0
            for (index, line) in lines.enumerated() {
                let length = (line as NSString).length
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let isEdge = index == nonempty.first || index == nonempty.last
                let isNumber = trimmed.range(of: "^[-–—]?\\s*\\d+\\s*[-–—]?$", options: .regularExpression) != nil
                if isNumber || (isEdge && edges.contains(trimmed)) {
                    removals.append(NSRange(location: start, length: length + (index < lines.count - 1 ? 1 : 0)))
                }
                start += length + 1
            }
            for range in removals.reversed() {
                value.deleteCharacters(in: range); offsets.removeSubrange(range.location..<NSMaxRange(range))
            }
            let pattern = try! NSRegularExpression(pattern: "(?<=[\\p{L}])-\\s*\n\\s*(?=[\\p{L}])")
            for match in pattern.matches(in: value as String, range: NSRange(location: 0, length: value.length)).reversed() {
                value.deleteCharacters(in: match.range)
                offsets.removeSubrange(match.range.location..<NSMaxRange(match.range))
            }
        }
        let trimmed = (value as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", []) }
        let range = (value as NSString).range(of: trimmed)
        return (trimmed, Array(offsets[range.location..<NSMaxRange(range)]))
    }
    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let value = AVSpeechUtterance(string: text); value.rate = speechRate; value.pitchMultiplier = pitch
        if let voiceIdentifier { value.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) }
        else { value.voice = AVSpeechSynthesisVoice(language: detectedLanguage) }
        return value
    }
    private func speakCurrentPage(from offset: Int = 0) {
        guard !pageText.isEmpty else {
            if automaticOCR { recognizeCurrentPage(continueReading: true) }
            else { statusMessage = "Bu sayfa için OCR çalıştırın veya sonraki sayfaya geçin." }
            return
        }
        let text = pageText as NSString
        let safeOffset = min(max(offset, 0), text.length)
        guard safeOffset < text.length else { advanceToNextReadablePage(); return }
        utteranceOffset = safeOffset; resumeOffset = safeOffset
        shouldAdvance = true; isSpeaking = true; isPaused = false
        let utterance = makeUtterance(text.substring(from: safeOffset))
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }
    private func advanceToNextReadablePage() {
        guard canGoForward else { stop(); resumeOffset = 0; updateRecentPage(); statusMessage = "Belge tamamlandı."; return }
        currentPageIndex += 1; resumeOffset = 0; loadCurrentPageText(); updateRecentPage()
        speakCurrentPage()
    }
    private func remember(_ url: URL) {
        guard let data = try? makeBookmark(url) else { statusMessage = "Belge geçmişi için erişim kaydı oluşturulamadı."; return }
        recentDocuments.removeAll { $0.key == documentKey }
        recentDocuments.insert(.init(bookmark: data, name: fileName, lastPage: currentPageIndex, key: documentKey, offset: resumeOffset), at: 0)
        recentDocuments = Array(recentDocuments.prefix(5)); saveRecent()
    }
    private func updateRecentPage() {
        guard let index = recentDocuments.firstIndex(where: { $0.key == documentKey }) else { return }
        let old = recentDocuments[index]
        recentDocuments[index] = .init(bookmark: old.bookmark, name: old.name, lastPage: currentPageIndex, key: documentKey, offset: resumeOffset)
        saveRecent()
    }
    func exportAudio(allPages: Bool) {
        guard !isExporting, let document else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.aiff]
        panel.nameFieldStringValue = fileName + (allPages ? "" : "-sayfa-\(currentPageIndex + 1)") + ".aiff"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let indices = allPages ? Array(0..<pageCount) : [currentPageIndex]
        let key = documentKey, destinationCache = cacheURL, edges = excludedEdges
        let useOCR = automaticOCR, shouldClean = cleanText
        let voice = voiceIdentifier, rate = speechRate, tone = pitch
        var cache = cachedOCR
        stop(); isExporting = true; exportProgress = 0; exportStage = "Sayfalar hazırlanıyor"
        exportTask = Task { [weak self] in
            guard let self else { return }
            var texts: [String] = []
            var missing = 0
            for (position, index) in indices.enumerated() {
                guard !Task.isCancelled else { return }
                let page = document.page(at: index)
                var raw = cache[String(index)] ?? page?.string ?? ""
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, useOCR, let page {
                    exportStage = "OCR · Sayfa \(index + 1)"
                    raw = await Self.recognize(image: page.thumbnail(of: CGSize(width: 2400, height: 3200), for: .mediaBox))
                    guard !Task.isCancelled else { return }
                    if !raw.isEmpty { cache[String(index)] = raw }
                }
                let text = shouldClean ? Self.normalizedText(raw, excluding: edges) : raw
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing += 1 }
                else { texts.append(text) }
                exportProgress = Double(position + 1) / Double(indices.count) * 0.4
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            if let destinationCache, let data = try? JSONEncoder().encode(cache) {
                do {
                    try FileManager.default.createDirectory(at: destinationCache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destinationCache, options: .atomic)
                } catch { statusMessage = "OCR önbelleği kaydedilemedi." }
            }
            if documentKey == key {
                cachedOCR = cache
                if pageText.isEmpty { loadCurrentPageText() }
            }
            guard !texts.isEmpty else {
                isExporting = false; errorMessage = "Seslendirilebilir metin bulunamadı. OCR ayarını kontrol edin."; return
            }
            let utterances = texts.map { text -> AVSpeechUtterance in
                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = rate; utterance.pitchMultiplier = tone
                let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
                utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: recognizer.dominantLanguage?.rawValue ?? "tr")
                return utterance
            }
            exportStage = "Ses dosyası yazılıyor"
            let exporter = AudioExporter(); self.exporter = exporter
            exporter.start(utterances, to: url, progress: { [weak self] value in
                self?.exportProgress = 0.4 + value * 0.6
            }, completion: { [weak self] error in
                self?.isExporting = false; self?.exporter = nil; self?.exportTask = nil
                if let error {
                    if (error as NSError).domain != "PDFToVoice" || (error as NSError).code != 1 { self?.errorMessage = error.localizedDescription }
                }
                else { self?.statusMessage = missing == 0 ? "Ses dosyası kaydedildi." : "Ses kaydedildi. \(missing) metinsiz sayfa atlandı." }
            })
        }
    }
    func cancelExport() {
        exportTask?.cancel(); exportTask = nil
        exporter?.cancel(); exporter = nil
        isExporting = false; statusMessage = "Dışa aktarma iptal edildi."
    }

    private func saveRecent() { defaults.set(try? JSONEncoder().encode(recentDocuments), forKey: Keys.recent) }

    nonisolated private static func recognize(image: NSImage) async -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    continuation.resume(returning: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
                } catch { continuation.resume(returning: "") }
            }
        }
    }
}

extension ReaderModel: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.activeUtterance === utterance, self.shouldAdvance else { return }
            self.resumeOffset = range.location + self.utteranceOffset
            if Date().timeIntervalSince(self.lastPositionSave) > 2 {
                self.updateRecentPage(); self.lastPositionSave = Date()
            }
            self.spokenRange = NSRange(location: range.location + self.utteranceOffset, length: range.length)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.activeUtterance === utterance else { return }
            guard self.shouldAdvance else { self.stop(); return }
            self.isSpeaking = false; self.spokenRange = nil; self.advanceToNextReadablePage()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.activeUtterance === utterance else { return }; self.isSpeaking = false; self.isPaused = true; self.updateRecentPage() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.activeUtterance === utterance else { return }; self.isSpeaking = true; self.isPaused = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.activeUtterance === utterance else { return }; self.isSpeaking = false; self.isPaused = false; self.spokenRange = nil }
    }
}

/// Buffers are written in callback order; each page starts after the previous finishes.
@MainActor
final class AudioExporter {
    private let synthesizer = AVSpeechSynthesizer()
    private let sink = AudioSink()
    private var utterances: [AVSpeechUtterance] = []
    private var index = 0
    private var destination: URL?
    private var temporaryURL: URL?
    private var progress: ((Double) -> Void)?
    private var completion: ((Error?) -> Void)?
    private var finished = false
    func start(_ utterances: [AVSpeechUtterance], to url: URL, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        self.utterances = utterances; destination = url; self.progress = progress; self.completion = completion
        temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        sink.destination = temporaryURL
        writeNext()
    }
    private func writeNext() {
        guard index < utterances.count else { finish(nil); return }
        let sink = self.sink
        synthesizer.write(utterances[index]) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                Task { @MainActor in
                    guard let self, !self.finished else { return }
                    self.index += 1
                    self.progress?(Double(self.index) / Double(self.utterances.count))
                    self.writeNext()
                }
            } else {
                do { try sink.append(pcm) }
                catch { Task { @MainActor in self?.finish(error) } }
            }
        }
    }
    func cancel() {
        guard !finished else { return }
        finish(NSError(domain: "PDFToVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dışa aktarma iptal edildi."]))
    }
    private func finish(_ error: Error?) {
        guard !finished else { return }; finished = true
        synthesizer.stopSpeaking(at: .immediate); sink.close()
        var result = error
        if result == nil, let temporaryURL, let destination {
            do { try Data(contentsOf: temporaryURL, options: .mappedIfSafe).write(to: destination, options: .atomic) }
            catch { result = error }
        }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        completion?(result); completion = nil
    }
}

/// Consume each audio callback synchronously; buffers must not escape the callback.
private final class AudioSink: @unchecked Sendable {
    var destination: URL?
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var closed = false
    func append(_ pcm: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if file == nil, let destination {
            file = try AVAudioFile(forWriting: destination, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
        }
        try file?.write(from: pcm)
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; file = nil
    }
}
