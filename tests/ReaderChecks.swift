import AppKit
import AVFoundation
import PDFKit
import CoreText
import CryptoKit

@main
struct ReaderChecks {
    @MainActor static func main() async throws {
        let cleaned = ReaderModel.processText("  Başlık\nÖrnek keli-\nme burada.\n42\nAltbilgi  ", clean: true, excluding: ["Başlık", "Altbilgi"])
        precondition(cleaned.text == "Örnek kelime burada.", "Text cleanup")
        precondition(cleaned.offsets.count == (cleaned.text as NSString).length, "UTF-16 mapping length")
        let original = "  Başlık\nÖrnek keli-\nme burada.\n42\nAltbilgi  " as NSString
        let range = (cleaned.text as NSString).range(of: "burada")
        precondition(original.substring(with: NSRange(location: cleaned.offsets[range.location], length: range.length)) == "burada", "PDF highlight mapping")
        let emoji = ReaderModel.processText("😀 Türkçe\n", clean: false)
        precondition(emoji.offsets.count == (emoji.text as NSString).length, "Unicode mapping")
        precondition(ReaderModel.normalizedText("123\n\n").isEmpty, "Empty cleanup")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "reader-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ReaderModel(defaults: defaults, cacheDirectory: root.appendingPathComponent("cache"), makeBookmark: { try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) })
        let first = root.appendingPathComponent("first/book.pdf")
        let second = root.appendingPathComponent("second/book.pdf")
        try makePDF(first); try makePDF(second)
        model.open(first)
        try await loaded(model)
        precondition(model.pageCount == 2 && !model.pageText.isEmpty, "PDF loading")
        let foundPages = await model.searchPages("Second")
        precondition(foundPages.contains(1), "Document search")
        model.selectPage(1); model.toggleBookmark()
        precondition(model.bookmarks == [1], "Bookmark add")
        model.open(second); try await loaded(model)
        precondition(model.currentPageIndex == 0 && model.bookmarks.isEmpty, "Same-name document isolation")
        precondition(model.recentDocuments.count == 2, "Same-name recent documents")
        model.open(first); try await loaded(model)
        precondition(model.currentPageIndex == 1 && model.bookmarks == [1], "Position/bookmark persistence")
        model.recognizeCurrentPage()
        model.selectPage(0)
        let expected = model.pageText
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(model.pageText == expected && !model.isRunningOCR, "Stale OCR ignored")
        model.setSleepTimer(minutes: 5); precondition(model.sleepDeadline != nil)
        model.setSleepTimer(minutes: 0); precondition(model.sleepDeadline == nil)
        model.open(second); model.closeDocument()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.document == nil && !model.isLoading && !model.isRunningOCR, "Close during load")
        var items = try JSONDecoder().decode([ReaderModel.RecentDocument].self, from: defaults.data(forKey: "reader.recent")!)
        items[0].offset = 6
        defaults.set(try JSONEncoder().encode(items), forKey: "reader.recent")
        model.automaticOCR = false; model.cleanText = false
        let restored = ReaderModel(defaults: defaults, cacheDirectory: root.appendingPathComponent("cache"), makeBookmark: { try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) })
        precondition(!restored.automaticOCR && !restored.cleanText, "Preference persistence")
        restored.open(first); try await loaded(restored)
        precondition(restored.resumeOffset == 6, "Word position restored")
        restored.speechSynthesizer(AVSpeechSynthesizer(), willSpeakRangeOfSpeechString: NSRange(location: 0, length: 4), utterance: AVSpeechUtterance(string: "stale"))
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(restored.resumeOffset == 6 && restored.spokenRange == nil, "Stale speech callback ignored")
        restored.closeDocument()
        let key = SHA256.hash(data: Data(first.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = root.appendingPathComponent("cache/" + key + ".json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["0": "Cached OCR sample"]).write(to: cache)
        restored.open(first); try await loaded(restored)
        precondition(restored.pageText == "Cached OCR sample", "OCR cache restoration")
        restored.closeDocument()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: first.path)
        restored.open(first); try await loaded(restored)
        precondition(restored.pageText.contains("First") && !FileManager.default.fileExists(atPath: cache.path), "Changed PDF invalidates OCR cache")
        restored.closeDocument()
        print("Reader checks passed: cleanup, Unicode/PDF mapping, loading, search, identity, persistence, OCR cancellation, timer, close, preferences, word restoration, stale speech, OCR cache restoration/invalidation.")
    }
    @MainActor static func loaded(_ model: ReaderModel) async throws {
        for _ in 0..<500 {
            if !model.isLoading { precondition(model.document != nil, model.errorMessage ?? "Load failure"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Loading timed out")
    }
    static func makePDF(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in ["First page reading example", "Second page bookmark example"] {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 20)])
            context.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
